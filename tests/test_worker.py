import json
import os
import queue
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import synthesize
import tts_worker


class QueueStdin:
    """Line iterator that lets a test feed one worker command at a time."""

    def __init__(self):
        self.items = queue.Queue()

    def __iter__(self):
        return self

    def __next__(self):
        item = self.items.get()
        if item is None:
            raise StopIteration
        return item

    def send(self, value):
        self.items.put(json.dumps(value) + '\n')

    def close(self):
        self.items.put(None)


class CaptureStdout:
    def __init__(self):
        self.condition = threading.Condition()
        self.buffer = ''
        self.events = []

    def write(self, value):
        with self.condition:
            self.buffer += value
            while '\n' in self.buffer:
                line, self.buffer = self.buffer.split('\n', 1)
                if line:
                    self.events.append(json.loads(line))
            self.condition.notify_all()
        return len(value)

    def flush(self):
        return None

    def wait_for(self, predicate, timeout=2):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                matching = [event for event in self.events if predicate(event)]
                if matching:
                    return matching[-1]
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.fail_snapshot = list(self.events)
                    raise AssertionError(f'worker event timeout: {self.fail_snapshot!r}')
                self.condition.wait(remaining)


class FakeChunk:
    sample_channels = 1
    sample_width = 2
    sample_rate = 16000
    audio_int16_bytes = b'\x00\x00' * 160


class FakeVoice:
    def __init__(self):
        self.speakers = []

    def synthesize(self, text, config):
        self.speakers.append((text, config.speaker_id))
        yield FakeChunk()


def fake_piper_modules():
    config_module = types.ModuleType('piper.config')

    class FakeSynthesisConfig:
        def __init__(self, speaker_id=0):
            self.speaker_id = speaker_id

    config_module.SynthesisConfig = FakeSynthesisConfig
    piper_module = types.ModuleType('piper')
    piper_module.config = config_module
    return {'piper': piper_module, 'piper.config': config_module}


class WorkerTests(unittest.TestCase):
    def test_worker_disables_bytecode_in_signed_resources(self):
        self.assertTrue(sys.dont_write_bytecode)

    def run_worker(self, stream_function, idle_timeout=300):
        stdin = QueueStdin()
        stdout = CaptureStdout()
        fake_voice = FakeVoice()
        load_calls = []

        def load(model):
            load_calls.append(Path(model))
            return fake_voice

        old_stdin, old_stdout, old_argv = sys.stdin, sys.stdout, sys.argv
        load_patch = patch.object(tts_worker, 'load_voice', load)
        stream_patch = patch.object(tts_worker, 'stream_to_directory', stream_function)
        load_patch.start()
        stream_patch.start()
        sys.stdin = stdin
        sys.stdout = stdout
        sys.argv = [
            'tts_worker.py', '--model', str(ROOT / 'models/model.onnx'),
            '--speaker', '0', '--idle-timeout', str(idle_timeout),
        ]
        thread = threading.Thread(target=tts_worker.main)
        thread.start()
        stdout.wait_for(lambda event: event.get('event') == 'ready')
        return (stdin, stdout, fake_voice, load_calls, thread,
                (old_stdin, old_stdout, old_argv, load_patch, stream_patch))

    def stop_worker(self, stdin, thread, old_streams):
        if thread.is_alive():
            stdin.close()
            thread.join(2)
        self.assertFalse(thread.is_alive(), 'worker did not stop after stdin EOF')
        sys.stdin, sys.stdout, sys.argv, load_patch, stream_patch = old_streams
        stream_patch.stop()
        load_patch.stop()

    def test_stream_contract_is_atomic_and_reports_chunks(self):
        voice = FakeVoice()
        callback_counts = []
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.dict(sys.modules, fake_piper_modules()):
                synthesize.stream_to_directory(
                    'Erster Satz. Zweiter Satz.', voice, 3, directory,
                    on_chunk=callback_counts.append)
            state = json.loads((directory / 'status.json').read_text())
            self.assertEqual(state, {'count': 2, 'done': True})
            self.assertEqual(callback_counts, [1, 2])
            self.assertEqual(sorted(path.name for path in directory.glob('*.wav')),
                             ['chunk-00000.wav', 'chunk-00001.wav'])
            self.assertEqual(sorted(path.name for path in directory.glob('*.json')),
                             ['chunk-00000.json', 'chunk-00001.json', 'status.json'])
            self.assertFalse(list(directory.glob('*.next')))
            self.assertEqual(voice.speakers, [('Erster Satz.', 3), ('Zweiter Satz.', 3)])

    def test_cancelled_stream_raises_before_done_status(self):
        voice = FakeVoice()
        cancel = threading.Event()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)

            def cancel_after_first(count):
                cancel.set()

            with patch.dict(sys.modules, fake_piper_modules()):
                with self.assertRaises(synthesize.SynthesisCancelled):
                    synthesize.stream_to_directory(
                        'Ein Satz. Noch einer.', voice, 0, directory, cancel,
                        cancel_after_first)
            state = json.loads((directory / 'status.json').read_text())
            self.assertFalse(state['done'])
            self.assertEqual(state['count'], 1)
            self.assertFalse(list(directory.glob('*.next')))

    def test_worker_reuses_one_loaded_voice_for_sequential_requests(self):
        def stream(text, voice, speaker, directory, cancel_event=None, on_chunk=None):
            directory = Path(directory)
            directory.mkdir(parents=True, exist_ok=True)
            voice.speakers.append((text, speaker))
            (directory / 'status.json').write_text(
                json.dumps({'count': 0, 'done': False}))
            if cancel_event is not None and cancel_event.is_set():
                raise synthesize.SynthesisCancelled()
            (directory / 'chunk-00000.wav').write_bytes(b'fake-audio')
            (directory / 'chunk-00000.json').write_text(json.dumps({'text': text}))
            (directory / 'status.json').write_text(
                json.dumps({'count': 1, 'done': False}))
            if on_chunk:
                on_chunk(1)
            (directory / 'status.json').write_text(
                json.dumps({'count': 1, 'done': True}))

        stdin, stdout, voice, load_calls, thread, old_streams = self.run_worker(stream)
        try:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for index in range(2):
                    request_id = f'warm-{index}'
                    directory = root / str(index)
                    directory.mkdir()
                    stdin.send({
                        'command': 'synthesize', 'request_id': request_id,
                        'text': 'Ein identischer Satz.', 'speaker': 0,
                        'output': str(directory / 'audio.wav'),
                        'stream_directory': str(directory),
                    })
                    stdout.wait_for(lambda event, request_id=request_id:
                                    event.get('event') == 'chunk' and
                                    event.get('request_id') == request_id)
                    stdout.wait_for(lambda event, request_id=request_id:
                                    event.get('event') == 'done' and
                                    event.get('request_id') == request_id)
                    state = json.loads((directory / 'status.json').read_text())
                    self.assertEqual(state, {'count': 1, 'done': True})
                self.assertEqual(load_calls, [ROOT / 'models/model.onnx'])
                self.assertEqual(len(voice.speakers), 2)
        finally:
            self.stop_worker(stdin, thread, old_streams)

    def test_cancel_cleans_partial_directory_and_worker_remains_reusable(self):
        load_calls = None

        def blocking_stream(text, voice, speaker, directory, cancel_event=None, on_chunk=None):
            directory = Path(directory)
            directory.mkdir(parents=True, exist_ok=True)
            (directory / 'status.json').write_text(json.dumps({'count': 0, 'done': False}))
            while not cancel_event.is_set():
                time.sleep(.005)
            raise synthesize.SynthesisCancelled()

        stdin, stdout, voice, load_calls, thread, old_streams = self.run_worker(blocking_stream)
        try:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                cancelled_directory = root / 'cancelled'
                cancelled_directory.mkdir()
                stdin.send({
                    'command': 'synthesize', 'request_id': 'cancel-me',
                    'text': 'Abbruch testen.', 'speaker': 0,
                    'output': str(cancelled_directory / 'audio.wav'),
                    'stream_directory': str(cancelled_directory),
                })
                stdout.wait_for(lambda event: event.get('event') == 'started' and
                                event.get('request_id') == 'cancel-me')
                stdin.send({'command': 'cancel', 'request_id': 'cancel-me'})
                stdin.send({
                    'command': 'synthesize', 'request_id': 'queued-during-cancel',
                    'text': 'Darf nicht verloren gehen.', 'speaker': 0,
                    'output': str(root / 'queued' / 'audio.wav'),
                    'stream_directory': str(root / 'queued'),
                })
                busy = stdout.wait_for(
                    lambda event: event.get('event') == 'error' and
                    event.get('request_id') == 'queued-during-cancel')
                self.assertEqual(busy['error'], 'Worker ist bereits beschäftigt.')
                stdout.wait_for(lambda event: event.get('event') == 'cancelled' and
                                event.get('request_id') == 'cancel-me')
                self.assertFalse(cancelled_directory.exists())
                self.assertFalse(any(event.get('event') == 'done' and
                                     event.get('request_id') == 'cancel-me'
                                     for event in stdout.events))

                # The process can accept a new request after cancellation and
                # still uses the same loaded voice object.
                def quick_stream(text, voice, speaker, directory, cancel_event=None, on_chunk=None):
                    directory = Path(directory)
                    directory.mkdir(parents=True, exist_ok=True)
                    (directory / 'status.json').write_text(json.dumps({'count': 1, 'done': True}))
                    if on_chunk:
                        on_chunk(1)

                with patch.object(tts_worker, 'stream_to_directory', quick_stream):
                    ready_directory = root / 'after-cancel'
                    ready_directory.mkdir()
                    stdin.send({
                        'command': 'synthesize', 'request_id': 'after-cancel',
                        'text': 'Weiter.', 'speaker': 0,
                        'output': str(ready_directory / 'audio.wav'),
                        'stream_directory': str(ready_directory),
                    })
                    stdout.wait_for(lambda event: event.get('event') == 'chunk' and
                                    event.get('request_id') == 'after-cancel')
                    stdout.wait_for(lambda event: event.get('event') == 'done' and
                                    event.get('request_id') == 'after-cancel')
                    self.assertEqual(len(load_calls), 1)
        finally:
            self.stop_worker(stdin, thread, old_streams)

    def test_idle_timeout_exits_after_terminal_request(self):
        def quick_stream(text, voice, speaker, directory, cancel_event=None, on_chunk=None):
            directory = Path(directory)
            directory.mkdir(parents=True, exist_ok=True)
            (directory / 'status.json').write_text(json.dumps({'count': 1, 'done': True}))
            if on_chunk:
                on_chunk(1)

        stdin, stdout, voice, load_calls, thread, old_streams = self.run_worker(
            quick_stream, idle_timeout=.05)
        try:
            stdout.wait_for(lambda event: event.get('event') == 'idle_timeout', timeout=1)
            thread.join(1)
            self.assertFalse(thread.is_alive())
            self.assertEqual(len(load_calls), 1)
        finally:
            self.stop_worker(stdin, thread, old_streams)


if __name__ == '__main__':
    unittest.main()
