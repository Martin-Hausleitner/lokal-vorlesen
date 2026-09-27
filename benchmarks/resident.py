#!/usr/bin/env python3
"""Measure worker launch separately from requests using an already loaded model."""
import argparse
import json
import os
import platform
import selectors
import subprocess
import tempfile
import time
import wave
from pathlib import Path
from run import TEXT, digest, summary


class Events:
    def __init__(self, pipe):
        self.selector = selectors.DefaultSelector()
        self.selector.register(pipe, selectors.EVENT_READ)
        self.pipe = pipe
        self.buffer = b''
        self.eof = False

    def read(self, delay=.005):
        result = []
        if self.selector.select(delay):
            data = os.read(self.pipe.fileno(), 65536)
            if not data:
                self.eof = True
                return result
            self.buffer += data
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                result.append(json.loads(line))
        return result

    def close(self):
        self.selector.close()


def validate_stream(directory):
    try:
        state = json.loads((directory / 'status.json').read_text())
        chunks = sorted(directory.glob('chunk-*.wav'))
        if not state['done'] or not chunks or len(chunks) != state['count']:
            return False
        for chunk in chunks:
            with wave.open(str(chunk)) as audio:
                frames = audio.getnframes()
                if not frames or len(audio.readframes(frames)) != frames * audio.getnchannels() * audio.getsampwidth():
                    return False
        return True
    except (OSError, ValueError, KeyError, EOFError, wave.Error):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', type=Path, required=True)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=10)
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.runs < 2 or args.timeout <= 0 or args.output.exists():
        parser.error('Use runs >= 2, positive timeout, and a new output path.')
    python, worker, model = (p.expanduser().absolute() for p in (args.python, args.worker, args.model))
    versions = subprocess.run([str(python), '-c', 'import sys,json,importlib.metadata as m; print(json.dumps({"python":sys.version,"piper":m.version("piper-tts"),"onnxruntime":m.version("onnxruntime")}))'], capture_output=True, text=True, timeout=args.timeout, check=True)
    report = {'schema_version': 1, 'platform': platform.platform(), 'versions': json.loads(versions.stdout), 'scope': 'Private stdin/stdout worker backend only. Startup includes process launch and model readiness. Requests are sequential in the same process; disk caches uncontrolled. No GUI, OCR or audible-playback measurement.',
        'model_sha256': digest(model), 'config_sha256': digest(Path(str(model) + '.json')),
        'worker_sha256': digest(worker), 'synthesis_sha256': digest(worker.with_name('synthesize.py')),
        'benchmark_sha256': digest(Path(__file__)), 'text': TEXT,
        'timeout_seconds': args.timeout, 'poll_interval_seconds': .005,
        'p95_method': 'nearest-rank, successful samples only', 'samples': []}
    with tempfile.TemporaryDirectory(prefix='lokal-resident-benchmark-') as temporary:
        root = Path(temporary)
        with (root / 'stderr').open('w+') as errors:
            started = time.perf_counter()
            process = subprocess.Popen([str(python), str(worker), '--model', str(model), '--speaker', '0'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=False)
            events = Events(process.stdout)
            try:
                ready = False
                while time.perf_counter() - started < args.timeout:
                    for event in events.read():
                        if event.get('event') == 'ready':
                            ready = True
                    if ready or events.eof:
                        break
                report['startup_seconds'] = time.perf_counter() - started
                report['ready'] = ready
                if ready:
                    for index in range(args.runs):
                        directory = root / str(index)
                        directory.mkdir()
                        request = str(index)
                        begin = time.perf_counter()
                        launch_offset = begin - started
                        message = {'command': 'synthesize', 'request_id': request, 'text': TEXT,
                            'output': str(directory / 'unused.wav'), 'stream_directory': str(directory)}
                        process.stdin.write((json.dumps(message) + '\n').encode())
                        process.stdin.flush()
                        first = None
                        terminal = None
                        while time.perf_counter() - begin < args.timeout:
                            if first is None and (directory / 'chunk-00000.wav').exists():
                                first = time.perf_counter() - begin
                            for event in events.read():
                                if event.get('request_id') == request and event.get('event') in ('done', 'error', 'cancelled'):
                                    terminal = event
                            if terminal or events.eof:
                                break
                        elapsed = time.perf_counter() - begin
                        if first is None and (directory / 'chunk-00000.wav').exists():
                            first = elapsed
                        ok = bool(terminal and terminal['event'] == 'done' and first is not None and validate_stream(directory))
                        row = {'run': index + 1, 'first_buffer_seconds': first,
                            'completion_seconds': elapsed, 'ok': ok,
                            'launch_to_first_buffer_seconds': launch_offset + first if first is not None else None,
                            'timeout': not terminal and not events.eof, 'terminal': terminal}
                        report['samples'].append(row)
                        print(json.dumps(row), flush=True)
                        if not ok:
                            break
                    if report['samples'] and report['samples'][0]['first_buffer_seconds'] is not None:
                        report['launch_to_first_buffer_seconds'] = report['samples'][0]['launch_to_first_buffer_seconds']
                    report['worker_pid'] = process.pid
                    memory = subprocess.run(['ps', '-o', 'rss=', '-p', str(process.pid)], capture_output=True, text=True)
                    report['rss_kib_after_requests'] = int(memory.stdout.strip()) if memory.returncode == 0 and memory.stdout.strip().isdigit() else None
            finally:
                events.close()
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                process.stdin.close()
                process.stdout.close()
                errors.seek(0)
                report['stderr_excerpt'] = errors.read(2000)
    report['summary'] = {phase: {key: summary(rows, key) for key in ('first_buffer_seconds', 'completion_seconds')}
        for phase, rows in [('first_request_after_ready', report['samples'][:1]), ('subsequent_requests', report['samples'][1:])]}
    report['ok'] = report['ready'] and len(report['samples']) == args.runs and all(s['ok'] for s in report['samples'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as output:
        json.dump(report, output, indent=2)
        output.write('\n')
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
