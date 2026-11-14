# Portions Copyright © 2026 Apple Inc. (mlx-lm, MIT License; see LICENSE.mlx-lm). Modifications Copyright © 2026 Preferred Networks, Inc.
# Adapted from mlx-lm 05b7aed425453057c511ec0d5ec9732c325b3444.
# Source-compatible PLaMo translation YaRN, normalization and window boundaries.

from dataclasses import dataclass
from typing import Any

import mlx.core as mx
import mlx.nn as nn
from mlx_lm.models.base import BaseModelArgs, create_attention_mask, scaled_dot_product_attention
from mlx_lm.models.cache import KVCache, RotatingKVCache


@dataclass
class ModelArgs(BaseModelArgs):
    model_type: str = "plamo3"
    hidden_size: int = 4096
    num_hidden_layers: int = 32
    rms_norm_eps: float = 1e-6
    tie_word_embeddings: bool = True
    scale_embedding: bool = False
    rope_scaling_factor: float | None = None
    initial_context_length: int | None = None
    plamo_rope_inv_freq: dict | None = None
    num_attention_heads: int = 32
    num_key_value_heads: int = 4
    head_dim: int = 128
    max_position_embeddings: int = 2048
    window_size: int = 2048
    sliding_window: int | None = None
    sliding_window_pattern: int = 8
    rope_theta: float = 1_000_000
    rope_local_theta: float = 10_000
    intermediate_size: int = 13312
    vocab_size: int = 32000
    image_token_id: int | None = None
    image_feature_size: int | None = None
    image_proj_type: str = "linear"
    linear_type: str = "normal"

    def __post_init__(self):
        if self.sliding_window is not None:
            self.window_size = self.sliding_window


def is_full_attention(args: ModelArgs, layer_idx: int) -> bool:
    return not bool((layer_idx + 1) % args.sliding_window_pattern)


class RMSNorm(nn.Module):
    def __init__(
        self,
        hidden_size: int,
        eps: float = 1e-6,
        offset: float = 1.0,
    ) -> None:
        super().__init__()
        self.weight = mx.zeros(hidden_size)
        self.variance_epsilon = eps
        self.offset = offset
        self._scale = None
        self._scale_weight = None

    @property
    def scale(self) -> mx.array:
        if self.offset == 0:
            return self.weight
        if self.training:
            return self.weight + self.offset
        if self._scale is None or self._scale_weight is not self.weight:
            self._scale = self.weight + self.offset
            self._scale_weight = self.weight
        return self._scale

    def __call__(self, hidden_states: mx.array) -> mx.array:
        # HF rounds the normalized activation before multiplying the BF16 scale.
        value = hidden_states.astype(mx.float32)
        value = value * mx.rsqrt(mx.mean(value * value, axis=-1, keepdims=True) + self.variance_epsilon)
        return value.astype(hidden_states.dtype) * self.scale


class SourceRoPE(nn.Module):
    """HF YaRN frequencies and arithmetic, including the low precision roundings.

    Frequencies are computed once from the pinned HF source and serialized as
    FP32-exact JSON numbers. Recomputing pow/reciprocal on each backend introduces
    phase drift at long positions. Private arrays survive model.set_dtype().
    """

    def __init__(self, config: ModelArgs, full_attention: bool):
        super().__init__()
        import math

        if config.plamo_rope_inv_freq is None:
            raise ValueError("config.json lacks plamo_rope_inv_freq; re-download the model files")
        key = "full" if full_attention else "local"
        values = config.plamo_rope_inv_freq[key]
        if len(values) != config.head_dim // 2:
            raise ValueError("Invalid source RoPE dimensions")
        self._inv_freq = mx.array(values, dtype=mx.float32)
        self._concentration = (
            1 + 0.1 * math.log(config.rope_scaling_factor)
            if full_attention and config.rope_scaling_factor not in (None, 1)
            else 1.0
        )

    def __call__(self, x: mx.array, offset=0):
        positions = mx.arange(x.shape[-2], dtype=mx.float32)
        if isinstance(offset, mx.array) and offset.ndim:
            positions = positions[None, :] + offset.astype(mx.float32)[:, None]
            phase = positions[:, None, :, None] * self._inv_freq
        else:
            phase = (positions + offset)[..., None] * self._inv_freq
        phase = mx.concatenate([phase, phase], axis=-1)
        cos = mx.cos(phase).astype(x.dtype) * self._concentration
        sin = mx.sin(phase).astype(x.dtype) * self._concentration
        half = x.shape[-1] // 2
        rotated = mx.concatenate([-x[..., half:], x[..., :half]], axis=-1)
        return x * cos + rotated * sin


class Attention(nn.Module):
    def __init__(self, config: ModelArgs, layer_idx: int) -> None:
        super().__init__()
        self.config = config
        self.layer_idx = layer_idx
        self.hidden_size = config.hidden_size
        head_dim = config.head_dim
        self.scale = head_dim**-0.5

        self.q_num_heads = config.num_attention_heads
        self.qk_dim = self.v_dim = head_dim
        self.k_num_heads = self.v_num_heads = config.num_key_value_heads
        assert self.q_num_heads % self.k_num_heads == 0

        self.q_proj_dim = self.q_num_heads * self.qk_dim
        self.k_proj_dim = self.k_num_heads * self.qk_dim
        self.v_proj_dim = self.v_num_heads * self.v_dim
        self.qkv_proj = nn.Linear(
            self.hidden_size,
            self.q_proj_dim + self.k_proj_dim + self.v_proj_dim,
            bias=False,
        )
        self.o_proj = nn.Linear(self.q_num_heads * self.v_dim, self.hidden_size, bias=False)

        self.q_norm = RMSNorm(self.qk_dim, eps=config.rms_norm_eps, offset=1.0)
        self.k_norm = RMSNorm(self.qk_dim, eps=config.rms_norm_eps, offset=1.0)

        self.full_attn = is_full_attention(config, layer_idx)
        self.rope = SourceRoPE(config, self.full_attn)

    def __call__(
        self,
        hidden_states: mx.array,
        mask: mx.array | None = None,
        cache: Any | None = None,
    ) -> mx.array:
        B, L, _ = hidden_states.shape

        # AutoRound stores affine scales in FP16. MLX promotes BF16 x FP16
        # to FP32; restore the source activation dtype at each linear boundary.
        qkv = self.qkv_proj(hidden_states).astype(hidden_states.dtype)
        queries, keys, values = mx.split(
            qkv,
            [self.q_proj_dim, self.q_proj_dim + self.k_proj_dim],
            axis=-1,
        )

        queries = queries.reshape(B, L, self.q_num_heads, self.qk_dim).transpose(0, 2, 1, 3)
        keys = keys.reshape(B, L, self.k_num_heads, self.qk_dim).transpose(0, 2, 1, 3)
        values = values.reshape(B, L, self.v_num_heads, self.v_dim).transpose(0, 2, 1, 3)

        queries = self.q_norm(queries)
        keys = self.k_norm(keys)

        if cache is not None:
            offset = cache.offset
            queries = self.rope(queries, offset=offset)
            keys = self.rope(keys, offset=offset)
            keys, values = cache.update_and_fetch(keys, values)
        else:
            queries = self.rope(queries)
            keys = self.rope(keys)

        output = scaled_dot_product_attention(
            queries,
            keys,
            values,
            cache=cache,
            scale=self.scale,
            mask=mask,
        )
        output = output.transpose(0, 2, 1, 3).reshape(B, L, self.q_num_heads * self.v_dim)
        return self.o_proj(output).astype(hidden_states.dtype)


class MLP(nn.Module):
    def __init__(self, config: ModelArgs) -> None:
        super().__init__()
        self.gate_up_proj = nn.Linear(config.hidden_size, config.intermediate_size * 2, bias=False)
        self.down_proj = nn.Linear(config.intermediate_size, config.hidden_size, bias=False)

    def __call__(self, x: mx.array) -> mx.array:
        gate, value = mx.split(self.gate_up_proj(x).astype(x.dtype), 2, axis=-1)
        # torch.nn.functional.silu rounds once to the input dtype, while
        # sigmoid and multiply separately in BF16 introduce an extra rounding.
        gate_f32 = gate.astype(mx.float32)
        activated = (gate_f32 * mx.sigmoid(gate_f32)).astype(gate.dtype)
        return self.down_proj(activated * value).astype(x.dtype)


class Plamo3DecoderLayer(nn.Module):
    def __init__(self, config: ModelArgs, layer_idx: int) -> None:
        super().__init__()
        self.config = config
        self.hidden_size = config.hidden_size
        self.full_attn = is_full_attention(config, layer_idx)
        self.mixer = Attention(config, layer_idx)
        self.mlp = MLP(config)
        self.pre_mixer_norm = RMSNorm(config.hidden_size, eps=config.rms_norm_eps, offset=1.0)
        self.post_mixer_norm = RMSNorm(config.hidden_size, eps=config.rms_norm_eps, offset=1.0 / 5)
        self.pre_mlp_norm = RMSNorm(config.hidden_size, eps=config.rms_norm_eps, offset=1.0)
        self.post_mlp_norm = RMSNorm(config.hidden_size, eps=config.rms_norm_eps, offset=1.0 / (5**1.5))

    def __call__(
        self,
        hidden_states: mx.array,
        mask: mx.array | None = None,
        cache: Any | None = None,
    ) -> mx.array:
        residual = hidden_states
        hidden_states = self.pre_mixer_norm(hidden_states)
        hidden_states_sa = self.mixer(hidden_states, mask=mask, cache=cache)
        hidden_states = residual + self.post_mixer_norm(hidden_states_sa)

        residual = hidden_states
        hidden_states = self.pre_mlp_norm(hidden_states)
        hidden_states_mlp = self.mlp(hidden_states)
        return residual + self.post_mlp_norm(hidden_states_mlp)


class Plamo3Decoder(nn.Module):
    def __init__(self, config: ModelArgs) -> None:
        super().__init__()
        self.config = config
        self.window_size = config.window_size
        self.layers = [Plamo3DecoderLayer(config, layer_idx=i) for i in range(config.num_hidden_layers)]
        self.full_idx = next((i for i, layer in enumerate(self.layers) if layer.full_attn), 0)
        self.swa_idx = next((i for i, layer in enumerate(self.layers) if not layer.full_attn), None)

    def __call__(self, x: mx.array, cache: Any | None = None) -> mx.array:
        if cache is None:
            cache = [None] * len(self.layers)

        full_mask = create_attention_mask(x, cache[self.full_idx])
        sliding_window_mask = None
        if self.swa_idx is not None:
            sliding_window_mask = create_attention_mask(
                x,
                cache[self.swa_idx],
                window_size=self.window_size,
            )

        for layer, c in zip(self.layers, cache):
            mask = full_mask if layer.full_attn else sliding_window_mask
            x = layer(x, mask=mask, cache=c)
        return x


class Plamo3Model(nn.Module):
    def __init__(self, config: ModelArgs):
        super().__init__()
        self.config = config
        self.vocab_size = config.vocab_size
        self.embed_tokens = nn.Embedding(config.vocab_size, config.hidden_size)
        self.layers = Plamo3Decoder(config)
        self.norm = RMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def __call__(
        self,
        inputs: mx.array,
        cache: Any | None = None,
        input_embeddings: mx.array | None = None,
    ) -> mx.array:
        if input_embeddings is not None:
            h = input_embeddings
        else:
            h = self.embed_tokens(inputs)
            if self.config.scale_embedding:
                h = h * self.config.hidden_size**0.5

        h = self.layers(h, cache)
        return self.norm(h)


class Model(nn.Module):
    def __init__(self, config: ModelArgs) -> None:
        super().__init__()
        self.config = config
        self.model_type = config.model_type
        self.model = Plamo3Model(config)
        self.vocab_size = config.vocab_size

        if not config.tie_word_embeddings:
            self.lm_head: nn.Module = nn.Linear(config.hidden_size, self.vocab_size, bias=False)

    def sanitize(self, weights: dict[Any, Any]) -> dict[Any, Any]:
        if self.config.tie_word_embeddings:
            weights.pop("lm_head.weight", None)
        return weights

    def make_cache(self):
        caches = []
        for layer in self.layers:
            if layer.full_attn:
                c = KVCache()
            else:
                c = RotatingKVCache(max_size=self.config.window_size)
            caches.append(c)
        return caches

    def __call__(
        self,
        inputs: mx.array,
        cache: Any | None = None,
        input_embeddings: mx.array | None = None,
    ) -> mx.array:
        outputs = self.model(inputs, cache=cache, input_embeddings=input_embeddings)
        if self.config.tie_word_embeddings:
            return self.model.embed_tokens.as_linear(outputs).astype(mx.float32)
        return self.lm_head(outputs).astype(mx.float32)

    @property
    def layers(self):
        return self.model.layers.layers
