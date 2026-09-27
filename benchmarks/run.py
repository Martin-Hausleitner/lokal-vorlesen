#!/usr/bin/env python3
"""Measure actual streaming synthesis in separate processes; never touches the GUI."""
import argparse
import hashlib
import json
import math
import platform
import statistics
import subprocess
import tempfile
import time
import wave
from pathlib import Path

TEXT = 'Dieser Test misst die lokale Sprachausgabe. Der erste Puffer soll schnell bereitstehen.'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summary(samples, key):
    values = sorted(s[key] for s in samples if s['ok'] and s[key] is not None)
    return {'n': len(values), 'median': statistics.median(values) if values else None,
            'p95': values[math.ceil(.95 * len(values)) - 1] if values else None}


def measure(python, script, model, timeout):
    with tempfile.TemporaryDirectory(prefix='lokal-benchmark-') as temporary:
        root = Path(temporary)
        stream = root / 'stream'
        first = None
        timed_out = False
        # File-backed stderr avoids deadlock if a failing child emits large output.
        with (root / 'stderr').open('w+') as errors:
            start = time.perf_counter()
            process = subprocess.Popen([str(python), str(script), '--model', str(model),
                '--output', str(root / 'unused.wav'), '--stream-directory', str(stream)],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errors, text=True)
            try:
                try:
                    process.stdin.write(TEXT)
                    process.stdin.close()
                except BrokenPipeError:
                    pass
                while True:
                    elapsed = time.perf_counter() - start
                    if first is None and (stream / 'chunk-00000.wav').is_file():
                        first = elapsed
                    if process.poll() is not None:
                        break
                    if elapsed >= timeout:
                        timed_out = True
                        process.kill()
                        break
                    time.sleep(.005)
                process.wait()
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            total = time.perf_counter() - start
            errors.seek(0)
            error = errors.read(2000)
        valid = False
        try:
            status = json.loads((stream / 'status.json').read_text())
            chunks = sorted(stream.glob('chunk-*.wav'))
            valid = status['done'] and len(chunks) == status['count'] and bool(chunks)
            for chunk in chunks:
                with wave.open(str(chunk)) as audio:
                    frames = audio.getnframes()
                    valid = valid and frames > 0 and len(audio.readframes(frames)) == frames * audio.getnchannels() * audio.getsampwidth()
        except (OSError, ValueError, KeyError, wave.Error, EOFError):
            valid = False
        return {'first_buffer_seconds': first, 'completion_seconds': total,
                'exit_code': process.returncode, 'timeout': timed_out,
                'valid_complete_audio': bool(valid),
                'ok': process.returncode == 0 and not timed_out and valid and first is not None,
                'error': error if process.returncode else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', type=Path, required=True)
    parser.add_argument('--script', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=20)
    parser.add_argument('--timeout', type=float, default=30)
    args = parser.parse_args()
    if args.runs < 2 or args.timeout <= 0:
        parser.error('Use at least 2 runs and a positive timeout.')
    python, script, model = (p.expanduser().absolute() for p in (args.python, args.script, args.model))
    for path in (python, script, model, Path(str(model) + '.json')):
        if not path.is_file():
            parser.error(f'Missing file: {path}')
    if args.output.exists():
        parser.error('Output already exists; choose a new path.')
    versions = subprocess.run([str(python), '-c',
        'import sys,json,importlib.metadata as m; print(json.dumps({"python":sys.version,"piper":m.version("piper-tts"),"onnxruntime":m.version("onnxruntime")}))'],
        capture_output=True, text=True, timeout=args.timeout, check=True)
    report = {'schema_version': 1, 'scope': 'Backend only. Every request starts a new process and reloads the model. First observed request and subsequent sequential requests are reported separately. OS/disk caches are uncontrolled. No cold-cache, resident-model, GUI, OCR, or audible-playback claim.',
        'platform': platform.platform(), 'versions': json.loads(versions.stdout),
        'model_sha256': digest(model), 'config_sha256': digest(Path(str(model) + '.json')),
        'script_sha256': digest(script), 'benchmark_sha256': digest(Path(__file__)),
        'model_bytes': model.stat().st_size, 'text': TEXT, 'timeout_seconds': args.timeout,
        'poll_interval_seconds': .005, 'p95_method': 'nearest-rank, successful samples only', 'samples': []}
    for index in range(args.runs):
        sample = measure(python, script, model, args.timeout)
        sample.update(run=index + 1, phase='first_observed_process' if index == 0 else 'repeated_fresh_process')
        report['samples'].append(sample)
        print(json.dumps(sample), flush=True)
    report['summary'] = {name: {key: summary(samples, key) for key in
        ('first_buffer_seconds', 'completion_seconds')} for name, samples in
        [('all', report['samples']), ('first_observed', report['samples'][:1]),
         ('repeated', report['samples'][1:])]}
    report['failed_runs'] = sum(not s['ok'] for s in report['samples'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as output:
        json.dump(report, output, indent=2)
        output.write('\n')
    return 1 if report['failed_runs'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
