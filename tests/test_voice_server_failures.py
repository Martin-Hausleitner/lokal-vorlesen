import hashlib
import json
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

import voice_server


MODEL = b"valid-model"
MODEL_CONFIG = json.dumps(
    {"phoneme_id_map": {}, "phoneme_type": "text"}
).encode()


class StubResponse:
    def __init__(self, reads):
        self.reads = iter(reads)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self, _size):
        value = next(self.reads, b"")
        if isinstance(value, BaseException):
            raise value
        return value


class BlockingResponse(StubResponse):
    def __init__(self, started, release):
        super().__init__([MODEL])
        self.started = started
        self.release = release

    def read(self, size):
        if not self.started.is_set():
            self.started.set()
            self.release.wait(2)
        return super().read(size)


class VoiceServerFailureTests(unittest.TestCase):
    def make_library(self, root):
        catalog = root / "catalog.json"
        catalog.write_text(
            json.dumps(
                [
                    {
                        "id": "de_DE-thorsten-low",
                        "name": "Thorsten",
                        "speaker": 0,
                        "is_default": True,
                        "local_available": True,
                    },
                    {
                        "id": "candidate",
                        "name": "Candidate",
                        "speaker": 0,
                        "model_key": "candidate",
                        "model_bytes": len(MODEL),
                        "config_bytes": len(MODEL_CONFIG),
                        "model_md5": hashlib.md5(MODEL).hexdigest(),
                        "config_md5": hashlib.md5(MODEL_CONFIG).hexdigest(),
                        "model_url": "https://huggingface.co/test/candidate.onnx",
                        "config_url": "https://huggingface.co/test/candidate.onnx.json",
                        "phoneme_type": "text",
                        "local_available": True,
                    },
                ]
            ),
            encoding="utf-8",
        )
        state_dir = root / "state"
        state_dir.mkdir()
        (state_dir / "voice.json").write_text(
            json.dumps(
                {
                    "voice_id": "previous",
                    "name": "Previous",
                    "speaker": 0,
                    "model_path": "/previous/model.onnx",
                }
            ),
            encoding="utf-8",
        )
        return voice_server.Library(catalog, state_dir)

    def engine_modules(self, validation_started=None, validation_release=None):
        config_module = types.ModuleType("piper.config")

        class FakePiperConfig:
            @classmethod
            def from_dict(cls, _config):
                if validation_started is not None:
                    validation_started.set()
                if validation_release is not None:
                    validation_release.wait(2)
                return cls()

        config_module.PiperConfig = FakePiperConfig
        piper_module = types.ModuleType("piper")
        piper_module.config = config_module

        runtime_module = types.ModuleType("onnxruntime")

        class FakeSessionOptions:
            intra_op_num_threads = 0

        class FakeInferenceSession:
            def __init__(self, *_args, **_kwargs):
                pass

        runtime_module.SessionOptions = FakeSessionOptions
        runtime_module.InferenceSession = FakeInferenceSession
        return {
            "piper": piper_module,
            "piper.config": config_module,
            "onnxruntime": runtime_module,
        }

    def urlopen_for(self, model_reads, config_reads=(MODEL_CONFIG, b"")):
        def urlopen(url, timeout):
            del timeout
            if url.endswith(".json"):
                return StubResponse(config_reads)
            return StubResponse(model_reads)

        return urlopen

    def wait_for_terminal(self, library):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if library.state()["download"]["state"] != "downloading":
                return library.state()["download"]
            time.sleep(0.005)
        self.fail(f"download did not finish: {library.state()['download']!r}")

    def selected_config(self, library):
        return json.loads(library.state_file.read_text(encoding="utf-8"))

    def assert_no_partials(self, library):
        self.assertEqual(
            list((library.state_dir / "voices").glob("*/.download-*")), []
        )

    def test_interrupted_short_and_checksum_invalid_downloads_preserve_selection(self):
        failures = (
            ("interrupted", [b"partial", OSError("connection lost")]),
            ("short", [b"short"]),
            ("checksum-invalid", [b"wrong-model"]),
        )
        for label, reads in failures:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                library = self.make_library(Path(temporary))
                with patch.object(voice_server.urllib.request, "urlopen",
                                  side_effect=self.urlopen_for(reads)):
                    status = None
                    with patch.dict(sys.modules, self.engine_modules()):
                        self.assertTrue(library.select("candidate"))
                        status = self.wait_for_terminal(library)
                self.assertEqual(status["state"], "error")
                self.assertEqual(self.selected_config(library)["voice_id"], "previous")
                self.assert_no_partials(library)

                with patch.object(voice_server.urllib.request, "urlopen",
                                  side_effect=self.urlopen_for([MODEL])):
                    with patch.dict(sys.modules, self.engine_modules()):
                        self.assertTrue(library.select("candidate"))
                        retry = self.wait_for_terminal(library)
                self.assertEqual(retry["state"], "ready")
                self.assertEqual(self.selected_config(library)["voice_id"], "candidate")
                self.assert_no_partials(library)

    def test_concurrent_select_is_refused_while_download_is_in_progress(self):
        with tempfile.TemporaryDirectory() as temporary:
            library = self.make_library(Path(temporary))
            started = threading.Event()
            release = threading.Event()

            def urlopen(url, timeout):
                del timeout
                if url.endswith(".json"):
                    return StubResponse([MODEL_CONFIG, b""])
                return BlockingResponse(started, release)

            with patch.object(voice_server.urllib.request, "urlopen", side_effect=urlopen):
                with patch.dict(sys.modules, self.engine_modules()):
                    self.assertTrue(library.select("candidate"))
                    self.assertTrue(started.wait(1))
                    self.assertFalse(library.select("de_DE-thorsten-low"))
                    release.set()
                    status = self.wait_for_terminal(library)
            self.assertEqual(status["state"], "ready")
            self.assertEqual(self.selected_config(library)["voice_id"], "candidate")

    def test_cleanup_during_download_cannot_commit_and_removes_partial(self):
        with tempfile.TemporaryDirectory() as temporary:
            library = self.make_library(Path(temporary))
            before = library.state_file.read_bytes()
            started = threading.Event()
            release = threading.Event()

            with patch.object(voice_server.urllib.request, "urlopen",
                              side_effect=lambda url, timeout: (
                                  StubResponse([MODEL_CONFIG, b""])
                                  if url.endswith(".json")
                                  else BlockingResponse(started, release))):
                with patch.dict(sys.modules, self.engine_modules()):
                    self.assertTrue(library.select("candidate"))
                    self.assertTrue(started.wait(1))
                    library.cleanup()
                    self.assert_no_partials(library)
                    release.set()
                    self.wait_for_terminal(library)
            self.assertEqual(library.state_file.read_bytes(), before)
            self.assert_no_partials(library)

    def test_cleanup_during_validation_cannot_commit_new_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            library = self.make_library(Path(temporary))
            before = library.state_file.read_bytes()
            validation_started = threading.Event()
            validation_release = threading.Event()
            modules = self.engine_modules(validation_started, validation_release)

            with patch.object(voice_server.urllib.request, "urlopen",
                              side_effect=self.urlopen_for([MODEL])):
                with patch.dict(sys.modules, modules):
                    self.assertTrue(library.select("candidate"))
                    self.assertTrue(validation_started.wait(1))
                    library.cleanup()
                    validation_release.set()
                    self.wait_for_terminal(library)
            self.assertEqual(library.state_file.read_bytes(), before)
            self.assertEqual(self.selected_config(library)["voice_id"], "previous")

    def test_default_selection_cannot_commit_after_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            library = self.make_library(Path(temporary))
            before = library.state_file.read_bytes()
            library.cleanup()
            library.download_voice("de_DE-thorsten-low")
            self.assertEqual(library.state_file.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
