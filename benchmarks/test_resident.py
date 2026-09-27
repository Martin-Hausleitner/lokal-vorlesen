import json
import os
import tempfile
import unittest
import wave
from pathlib import Path
from resident import Events, validate_stream


class ResidentBenchmarkTests(unittest.TestCase):
    def test_protocol_handles_split_lines_and_eof(self):
        read_fd, write_fd = os.pipe()
        with os.fdopen(read_fd, 'rb') as pipe:
            events = Events(pipe)
            try:
                os.write(write_fd, b'{"event":"rea')
                self.assertEqual(events.read(), [])
                os.write(write_fd, b'dy"}\n{"event":"done"}\n')
                self.assertEqual(events.read(), [{'event': 'ready'}, {'event': 'done'}])
                os.close(write_fd)
                events.read()
                self.assertTrue(events.eof)
            finally:
                events.close()

    def test_completed_status_needs_real_nonempty_audio(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'status.json').write_text(json.dumps({'done': True, 'count': 1}))
            self.assertFalse(validate_stream(directory))
            with wave.open(str(directory / 'chunk-00000.wav'), 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(16000)
                wav.writeframes(b'\x00\x00' * 100)
            self.assertTrue(validate_stream(directory))
            audio_path = directory / "chunk-00000.wav"
            audio_path.write_bytes(audio_path.read_bytes()[:44])
            self.assertFalse(validate_stream(directory))
            (directory / 'status.json').write_text(json.dumps({'done': False, 'count': 1}))
            self.assertFalse(validate_stream(directory))


if __name__ == '__main__':
    unittest.main()
