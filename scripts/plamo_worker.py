#!/usr/bin/env python3
"""Optional development worker. No text leaves loopback; model downloads are a separate step."""
import argparse
import hashlib
import importlib.util
import tempfile
import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN'] = '1'
os.environ['HF_HUB_OFFLINE'] = '1'

GLOSSARY = [
    {'source': 'confidentiality', 'target': '機密性'},
    {'source': 'integrity', 'target': '完全性'},
    {'source': 'availability', 'target': '可用性'},
    {'source': 'least privilege', 'target': '最小権限'},
    {'source': 'MFA', 'target': 'MFA（多要素認証）'},
    {'source': 'recovery time objective', 'target': '目標復旧時間（RTO）'},
    {'source': 'recovery point objective', 'target': '目標復旧時点（RPO）'},
    {'source': 'CISSP', 'target': 'CISSP'},
    {'source': 'ISC2', 'target': 'ISC2'},
]

def clean(text):
    if not isinstance(text, str) or '<|plamo:' in text:
        raise ValueError('Invalid text or reserved PFML token')
    return text

def prompt_for(text, context, glossary=None):
    # PFN's supplied template includes BOS and validates all fields.
    return tokenizer.apply_chat_template(
        [{'role': 'user', 'content': clean(text)}], source_lang='en', target_lang='ja',
        context=clean(context), glossary=glossary if glossary is not None else GLOSSARY, form='polite',
        add_generation_prompt=True, tokenize=False)

# The pinned PFN tokenizer uses Numba for one function and a typed dictionary.
# Keep the downloaded file intact so the asset verifier can validate and repair it.
PINNED_TOKENIZER = '68b769d516541603857ce9d2813e48193efe41abb64c1091311b973d491724d9'

def slim_model_view(model, scratch):
    source = model / 'tokenization_plamo.py'
    if not source.is_file():
        return model
    original = source.read_bytes()
    if hashlib.sha256(original).hexdigest() != PINNED_TOKENIZER:
        if b'from numba' in original:
            raise ValueError('このPLaMoトークナイザーは軽量版で未対応です。同梱モデルを準備してください。')
        return model
    code = '\n'.join(line for line in original.decode().split('\n')
                     if not line.startswith(('from numba ', 'from numba.', '    @njit')))
    code = code.replace('Dict.empty(key_type=types.int64, value_type=types.int32)', '{}')
    # Python/NumPy boolean addition differs from the compiled integer sum.
    code = code.replace('(c >= 0x80) + (c >= 0x800) + (c >= 0x10000)',
                        'int(c >= 0x80) + int(c >= 0x800) + int(c >= 0x10000)')
    view = scratch / 'plamo_slim'
    view.mkdir()
    for item in model.iterdir():
        if item == source:
            (view / item.name).write_text(code, encoding='utf-8')
        else:
            (view / item.name).symlink_to(item, target_is_directory=item.is_dir())
    return view

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # No transcripts in access logs.
    def do_POST(self):
        if self.path != '/translate':
            self.send_error(404); return
        # Reject browser requests, DNS rebinding and unwanted content types.
        if self.headers.get('Origin') or self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}':
            self.send_error(403); return
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 16000: raise ValueError('Request too large')
            obj = json.loads(self.rfile.read(size))
            text, context = clean(obj['text']), clean(obj.get('context', ''))
            if len(text) > 2000 or len(context) > 4000: raise ValueError('Text too large')
            custom = obj.get('glossary', [])
            if not isinstance(custom, list) or len(custom) > 16: raise ValueError('Invalid glossary')
            merged = {entry['source'].lower(): entry for entry in GLOSSARY}
            for term in custom:
                if not isinstance(term, dict) or set(term) != {'source', 'target'}: raise ValueError('Invalid glossary entry')
                source, target = clean(term['source']), clean(term['target'])
                if not 0 < len(source) <= 64 or not 0 < len(target) <= 96: raise ValueError('Invalid glossary length')
                merged[source.lower()] = {'source': source, 'target': target}
            relevant = [entry for entry in merged.values() if entry['source'].lower() in (text + ' ' + context).lower()]
            started = time.monotonic()
            chunks = list(stream_generate(model, tokenizer, prompt=prompt_for(text, context, relevant),
                max_tokens=512, sampler=make_sampler(temp=0)))
            if not chunks or chunks[-1].finish_reason != 'stop':
                raise ValueError('Generation did not reach EOS; no partial translation returned')
            result = ''.join(chunk.text for chunk in chunks).strip()
            if not result: raise ValueError('Empty translation')
            payload = {'translation': result, 'seconds': time.monotonic()-started,
                       'peak_gb': mx.get_peak_memory()/1e9, 'model': str(args.model),
                       'attribution': 'Built with PLaMo'}
            data = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        except Exception as error:
            data = json.dumps({'error': str(error)}).encode()
            self.send_response(422); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True, type=Path)
    parser.add_argument('--parent-pid', type=int)
    parser.add_argument('--port', type=int, default=8765, help='Use 0 for an OS-assigned available port')
    args = parser.parse_args()
    if not (args.model / 'config.json').is_file(): parser.error('Downloaded local model required')
    if args.parent_pid:
        import threading
        def parent_watch():
            while True:
                time.sleep(2)
                if os.getppid() != args.parent_pid:
                    os._exit(0)
        threading.Thread(target=parent_watch, daemon=True).start()
    started = time.monotonic()
    scratch = tempfile.TemporaryDirectory(prefix='rtranslate-plamo-') if importlib.util.find_spec('numba') is None else None
    if scratch:
        os.environ['HF_MODULES_CACHE'] = str(Path(scratch.name) / 'modules')
    import mlx.core as mx
    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler
    mx.set_cache_limit(256 * 1024 * 1024)
    try:
        model_path = args.model.resolve()
        if scratch:
            model_path = slim_model_view(model_path, Path(scratch.name))
        model, tokenizer = load(str(model_path), trust_remote_code=True,
                                tokenizer_config={'trust_remote_code': True})
        mx.eval(model.parameters())
    finally:
        if scratch: scratch.cleanup()
    server = HTTPServer(('127.0.0.1', args.port), Handler)
    print(json.dumps({'event': 'ready', 'port': server.server_port, 'load_seconds': time.monotonic()-started,
                       'peak_gb': mx.get_peak_memory()/1e9, 'attribution': 'Built with PLaMo'}), flush=True)
    server.serve_forever()
