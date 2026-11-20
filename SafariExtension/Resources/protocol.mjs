export const NATIVE_APP = 'local.webinarnihongo.app';
export const VOICES = [
  [2, '四国めたん'], [3, 'ずんだもん'], [8, '春日部つむぎ'],
  [10, '雨晴はう'], [14, '冥鳴ひまり'], [52, '雀松朱司']
];
export function webURL(value) {
  try { const u = new URL(value); return ['https:', 'http:'].includes(u.protocol) ? u.href : null; }
  catch { return null; }
}
export const SPEEDS = [1, 1.1, 1.2, 1.3, 1.4];
export const DEFAULT_SPEED = 1.2;
export function settings(value = {}) {
  return {
    volume: Math.max(0, Math.min(100, Number(value.volume) || 0)),
    speed: SPEEDS.includes(Number(value.speed)) ? Number(value.speed) : DEFAULT_SPEED,
    speaker: VOICES.some(([id]) => id === Number(value.speaker)) ? Number(value.speaker) : 2,
    autoSpeed: value.autoSpeed !== false,
    backend: value.backend === "Apple" ? "Apple" : "PLaMo",
    speechEngine: value.speechEngine === "Apple" ? "Apple" : "VOICEVOX",
    smooth: value.smooth !== false
  };
}
export function pcm16(samples) {
  const bytes = new Uint8Array(samples.length * 2), view = new DataView(bytes.buffer);
  samples.forEach((v, i) => view.setInt16(i * 2, Math.round(Math.max(-1, Math.min(1, v)) * (v < 0 ? 32768 : 32767)), true));
  return bytes;
}
// Retain fractional samples between callbacks, never reset the resampling clock per packet.
export class Resampler {
  constructor(rate) { this.rate = Math.round(rate); this.position = 0; this.samples = []; }
  push(input) {
    this.samples.push(...input); const out = [];
    while (this.position + this.rate <= this.samples.length * 16000) {
      const begin = this.position / 16000, end = (this.position + this.rate) / 16000;
      let total = 0;
      for (let i = Math.floor(begin); i < Math.ceil(end); i++) {
        total += this.samples[i] * Math.max(0, Math.min(i + 1, end) - Math.max(i, begin));
      }
      out.push(total * 16000 / this.rate); this.position += this.rate;
    }
    const used = Math.floor(this.position / 16000); this.samples.splice(0, used); this.position -= used * 16000;
    return out;
  }
}
export function mergeRows(existing, incoming) {
  const indexes = new Map(existing.map((row, i) => [row.id, i]));
  const result = existing.slice();
  for (const row of incoming) {
    if (typeof row.id !== 'string' || typeof row.japanese !== 'string') continue;
    if (indexes.has(row.id)) result[indexes.get(row.id)] = row;
    else { indexes.set(row.id, result.length); result.push(row); }
  }
  return result;
}
