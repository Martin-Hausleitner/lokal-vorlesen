#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
TASK_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lokalvorlesen-tests.XXXXXX")
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
for NAME in test-buffer-pause test-ocr-cancellation test-watchdog test-seek-reuse test-generation-completion test-reading-visibility; do
  xcrun clang -fobjc-arc -fblocks -O2 -Wno-unused-parameter -mmacosx-version-min=13.0 "tests/$NAME.m" src/OCRSelection.m src/LVAudioPlayer.m src/LVSpeechWorker.m -framework Cocoa -framework AVFoundation -framework Carbon -framework ApplicationServices -framework WebKit -framework Vision -framework ScreenCaptureKit -o "$TASK_TEST_DIR/$NAME"
  "$TASK_TEST_DIR/$NAME"
done
python3 -m py_compile synthesize.py voice_server.py
python3 -m unittest discover -s benchmarks -p 'test_*.py'
python3 -m unittest discover -s tests -p 'test_*.py'
if [[ -x runtime/bin/python3 && -f models/model.onnx ]]; then
  xcrun clang -fobjc-arc -fblocks -O2 tests/test-speech-worker.m src/LVSpeechWorker.m -framework Foundation -o "$TASK_TEST_DIR/test-speech-worker"
  "$TASK_TEST_DIR/test-speech-worker" "$PWD/runtime/bin/python3" "$PWD/tts_worker.py" "$PWD/models/model.onnx"
else
  print 'SKIP: native speech-worker integration requires setup.command runtime/model.'
fi
