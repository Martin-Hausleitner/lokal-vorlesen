#!/usr/bin/env python3
"""Loopback-only voice library. Downloads happen only on explicit selection."""
import argparse
import hashlib
import json
import os
import signal
from pathlib import Path
import tempfile
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = 8769


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.voice-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


class Library:
    def __init__(self, catalog, state_dir):
        self.voices = json.loads(catalog.read_text(encoding='utf-8'))
        if isinstance(self.voices, dict):
            self.voices = self.voices['voices']
        self.by_id = {v['id']: v for v in self.voices}
        self.state_dir = state_dir
        self.state_file = state_dir / 'voice.json'
        self.lock = threading.RLock()
        self.stopping = False
        self.partials = set()
        self.download = {'state': 'idle', 'voice_id': None, 'progress': 0, 'error': None}

    def config(self):
        try:
            config = json.loads(self.state_file.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            config = {}
        try:
            config['mode'] = json.loads((self.state_dir / 'player-mode.json').read_text())['mode']
        except (OSError, ValueError, KeyError):
            pass
        return config

    def state(self):
        with self.lock:
            config = self.config()
            return {'voices': self.voices, 'selected': config.get('voice_id', 'de_DE-thorsten-low'),
                    'download': dict(self.download), 'player_mode': config.get('mode', 'notch')}

    def set_mode(self, mode):
        if mode not in ('notch', 'bottom'):
            raise ValueError('Unbekannter Modus.')
        with self.lock:
            atomic_json(self.state_dir / 'player-mode.json', {'mode': mode})

    def select(self, voice_id):
        if voice_id not in self.by_id:
            raise ValueError('Diese Stimme ist nicht im Katalog.')
        if not self.by_id[voice_id].get('local_available', True):
            raise ValueError('Diese Stimme ist derzeit nur als Hörprobe verfügbar.')
        with self.lock:
            if self.stopping or self.download['state'] == 'downloading':
                return False
            self.download = {'state': 'downloading', 'voice_id': voice_id, 'progress': 0, 'error': None}
        threading.Thread(target=self.download_voice, args=(voice_id,), daemon=True).start()
        return True

    def download_voice(self, voice_id):
        voice = self.by_id[voice_id]
        try:
            if voice.get('is_default'):
                with self.lock:
                    if self.stopping:
                        raise RuntimeError('Stopping')
                    config = self.config()
                    config.update(voice_id=voice_id, name=voice['name'], speaker=voice.get('speaker', 0))
                    config.pop('model_path', None)
                    atomic_json(self.state_file, config)
                    self.download.update(state='ready', progress=100)
                return
            # Model identity comes solely from the bundled allowlisted catalog.
            model_key = voice.get('model_key', voice_id)
            if not model_key.replace('_', '').replace('-', '').isalnum():
                raise ValueError('Ungültige Modellkennung.')
            directory = self.state_dir / 'voices' / model_key
            directory.mkdir(parents=True, exist_ok=True)
            for index, kind in enumerate(('model', 'config')):
                target = directory / ('model.onnx' if kind == 'model' else 'model.onnx.json')
                expected_size = voice.get(kind + '_bytes')
                digest = voice.get(kind + '_md5')
                if target.is_file() and (not expected_size or target.stat().st_size == expected_size):
                    if not digest or hashlib.md5(target.read_bytes()).hexdigest() == digest:
                        continue
                url = voice[kind + '_url']
                parsed = urlparse(url)
                if parsed.scheme != 'https' or parsed.hostname not in ('huggingface.co', 'github.com'):
                    raise ValueError('Unbekannte Modellquelle.')
                with self.lock:
                    if self.stopping:
                        raise RuntimeError('Stopping')
                    fd, temporary = tempfile.mkstemp(prefix='.download-', dir=directory)
                    self.partials.add(temporary)
                try:
                    count = 0
                    md5 = hashlib.md5()
                    with os.fdopen(fd, 'wb') as output, urllib.request.urlopen(url, timeout=45) as response:
                        while chunk := response.read(262144):
                            if self.stopping:
                                raise RuntimeError('Stopping')
                            count += len(chunk)
                            if count > 700_000_000:
                                raise ValueError('Modelldatei ist unerwartet groß.')
                            output.write(chunk)
                            md5.update(chunk)
                            if kind == 'model' and expected_size:
                                with self.lock:
                                    self.download['progress'] = min(95, round(count / expected_size * 95))
                    if expected_size and count != expected_size:
                        raise ValueError('Download ist unvollständig.')
                    if digest and md5.hexdigest() != digest:
                        raise ValueError('Prüfsumme stimmt nicht überein.')
                    if kind == 'config':
                        parsed_config = json.loads(Path(temporary).read_text())
                        if 'phoneme_id_map' not in parsed_config:
                            raise ValueError('Ungültige Stimmendatei.')
                    os.replace(temporary, target)
                finally:
                    Path(temporary).unlink(missing_ok=True)
                    with self.lock:
                        self.partials.discard(temporary)
            # Validate actual engine compatibility before changing the selection.
            from piper.config import PiperConfig
            config_data = json.loads((directory / 'model.onnx.json').read_text())
            if config_data.get('phoneme_type', 'espeak') not in ('espeak', 'text', 'hebrew'):
                raise ValueError('Zusätzliche Sprachlaufzeit erforderlich.')
            PiperConfig.from_dict(config_data)
            import onnxruntime as ort
            options = ort.SessionOptions()
            options.intra_op_num_threads = 1
            session = ort.InferenceSession(str(directory / 'model.onnx'), sess_options=options,
                                           providers=['CPUExecutionProvider'])
            del session
            with self.lock:
                if self.stopping:
                    raise RuntimeError('Stopping')
                config = self.config()
                config.update(voice_id=voice_id, name=voice['name'],
                              model_path=str(directory / 'model.onnx'), speaker=voice.get('speaker', 0))
                atomic_json(self.state_file, config)
                self.download.update(state='ready', progress=100)
        except Exception:
            # No fetched contents, URLs, or user text in the error response.
            with self.lock:
                self.download.update(state='error', error='Stimme konnte nicht geladen werden. Bitte erneut versuchen.')

    def cleanup(self):
        with self.lock:
            self.stopping = True
            for temporary in self.partials:
                Path(temporary).unlink(missing_ok=True)
            self.partials.clear()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--web-dir', type=Path, required=True)
    parser.add_argument('--catalog', type=Path, required=True)
    parser.add_argument('--state-dir', type=Path, required=True)
    parser.add_argument('--instance-token', default='standalone-test')
    args = parser.parse_args()
    library = Library(args.catalog, args.state_dir)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *values):
            pass

        def local_request(self, changing=False):
            host = self.headers.get('Host', '')
            if host not in (f'127.0.0.1:{PORT}', f'localhost:{PORT}'):
                return False
            origin = self.headers.get('Origin')
            if origin and origin not in (f'http://127.0.0.1:{PORT}', f'http://localhost:{PORT}'):
                return False
            if self.headers.get('Sec-Fetch-Site') == 'cross-site':
                return False
            return not changing or self.headers.get('Content-Type', '').split(';')[0] == 'application/json'

        def respond(self, code, data, content_type='application/json'):
            payload = data if isinstance(data, bytes) else json.dumps(data, ensure_ascii=False).encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; media-src 'self' https://rhasspy.github.io https://huggingface.co; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            if not self.local_request():
                return self.respond(403, {'error': 'Nur lokal verfügbar.'})
            route = urlparse(self.path).path
            if route == '/api/voices':
                return self.respond(200, library.state())
            if route == '/api/health':
                return self.respond(200, {'application': 'LokalVorlesen', 'version': 2, 'instance_token': args.instance_token})
            if route in ('/', '/index.html'):
                return self.respond(200, (args.web_dir / 'index.html').read_bytes(), 'text/html; charset=utf-8')
            return self.respond(404, {'error': 'Nicht gefunden.'})

        def do_POST(self):
            if not self.local_request(changing=True):
                return self.respond(403, {'error': 'Anfrage nicht erlaubt.'})
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 4096:
                    return self.respond(413, {'error': 'Anfrage zu groß.'})
                data = json.loads(self.rfile.read(length))
                if self.path == '/api/select':
                    started = library.select(data.get('voice_id'))
                    return self.respond(202 if started else 409, {'ok': started})
                if self.path == '/api/mode':
                    library.set_mode(data.get('mode'))
                    return self.respond(200, {'ok': True})
                return self.respond(404, {'error': 'Nicht gefunden.'})
            except (ValueError, TypeError, AttributeError):
                return self.respond(400, {'error': 'Ungültige Auswahl.'})

    server = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    # Only clean old partials once this instance owns the listening port.
    for partial in (args.state_dir / 'voices').glob('*/.download-*'):
        partial.unlink(missing_ok=True)
    def terminate(signum, frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, terminate)
    try:
        server.serve_forever()
    finally:
        library.cleanup()
        server.server_close()


if __name__ == '__main__':
    main()
