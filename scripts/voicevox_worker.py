#!/usr/bin/env python3
"""Local VOICEVOX Core adapter. No media/text is persisted or logged."""
import argparse, json, os, threading, time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer
from voicevox_core.blocking import Onnxruntime, OpenJtalk, Synthesizer, VoiceModelFile

p = argparse.ArgumentParser()
p.add_argument('--root', type=Path, required=True)
p.add_argument('--parent-pid', type=int, required=True)
p.add_argument('--runtime', type=Path)
a = p.parse_args()
started = time.monotonic()
runtime = next((a.runtime or a.root / 'onnxruntime/lib').glob('libvoicevox_onnxruntime*.dylib'))
dictionary = next((a.root / 'dict').glob('open_jtalk_dic*'))
synth = Synthesizer(Onnxruntime.load_once(filename=str(runtime)), OpenJtalk(str(dictionary)),
                    acceleration_mode='CPU', cpu_num_threads=2)
# Inspect metadata without loading inference models. Only the selected VVM is loaded.
allowed_names = {'四国めたん', 'ずんだもん', '春日部つむぎ', '雨晴はう', '冥鳴ひまり', '雀松朱司'}
voices = []
model_paths = {}
for path in sorted((a.root / 'models/vvms').glob('*.vvm')):
    with VoiceModelFile.open(str(path)) as model:
        for meta in model.metas:
            if meta.name not in allowed_names:
                continue
            for style in meta.styles:
                if style.name == 'ノーマル' and style.type in ('talk', 'streaming_talk'):
                    voices.append({'id': style.id, 'name': meta.name + ' / ノーマル', 'credit': 'VOICEVOX:' + meta.name})
                    model_paths[style.id] = path
if not voices:
    raise SystemExit('No normal talk voice model was selected')
ids = set(model_paths)
loaded_path = None
loaded_id = None

def ensure_model(style):
    global loaded_path, loaded_id
    path = model_paths[style]
    if path == loaded_path:
        return
    if loaded_id is not None:
        synth.unload_voice_model(loaded_id)
        loaded_path = None
        loaded_id = None
    with VoiceModelFile.open(str(path)) as model:
        synth.load_voice_model(model)
        loaded_id = model.id
        loaded_path = path

def watch_parent():
    while True:
        time.sleep(2)
        try:
            os.kill(a.parent_pid, 0)
        except ProcessLookupError:
            os._exit(0)
threading.Thread(target=watch_parent, daemon=True).start()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def reply(self, status, data, mime='application/json'):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def permitted(self):
        return not self.headers.get('Origin') and self.headers.get('Host') == '127.0.0.1:50022'
    def do_GET(self):
        if not self.permitted():
            return self.reply(403, b'{}')
        if self.path != '/health':
            return self.reply(404, b'{}')
        self.reply(200, json.dumps({'voices': voices, 'loaded_model': loaded_path.name if loaded_path else None}).encode())
    def do_POST(self):
        if not self.permitted() or self.path != '/tts':
            return self.reply(403, b'{}')
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 16000:
                return self.reply(413, b'{}')
            if self.headers.get('Content-Type') != 'application/json':
                return self.reply(415, b'{}')
            request = json.loads(self.rfile.read(length))
            text = request['text']
            style = int(request['speaker'])
            speed = float(request['speed'])
            if not isinstance(text, str) or not 0 < len(text) <= 1200 or style not in ids or not .75 <= speed <= 2:
                return self.reply(400, b'{}')
            ensure_model(style)
            query = synth.create_audio_query(text, style)
            query.speed_scale = speed
            wav = synth.synthesis(query, style)
            self.reply(200, wav, 'audio/wav')
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            self.reply(500, b'{"error":"VOICEVOX synthesis failed"}')

server = HTTPServer(('127.0.0.1', 50022), Handler)
print(json.dumps({'event': 'ready', 'load_seconds': time.monotonic() - started, 'voices': voices}, ensure_ascii=False), flush=True)
server.serve_forever()
