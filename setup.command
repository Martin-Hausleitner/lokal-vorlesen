#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
command -v uv >/dev/null || { print 'uv fehlt.'; exit 1; }
[[ -x runtime/bin/python3 ]] || uv venv --python 3.12 runtime
uv pip install --python runtime/bin/python3 -r requirements.txt
mkdir -p models
BASE='https://huggingface.co/rhasspy/piper-voices/resolve/c10ece1aade47bb51c153c893d14e5bf8e5b7117/de/de_DE/thorsten/low'
if [[ ! -f models/model.onnx ]]; then
  TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/lokalvorlesen.XXXXXX")
  trap 'rm -rf "$TASK_TMP"' EXIT
  curl -fL --retry 0 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-thorsten-low-int8.tar.bz2' -o "$TASK_TMP/model.tar.bz2"
  print "1d845c838b08a99dd1f86e7169a6696da6dac61530ee4a81446a20e009948233  $TASK_TMP/model.tar.bz2" | shasum -a 256 -c
  tar -xOf "$TASK_TMP/model.tar.bz2" vits-piper-de_DE-thorsten-low-int8/de_DE-thorsten-low.onnx > models/model.onnx
fi
[[ -f models/model.onnx.json ]] || curl -fL --retry 0 "$BASE/de_DE-thorsten-low.onnx.json" -o models/model.onnx.json
shasum -a 256 -c <<'HASHES'
264f5b1d689355b0e0bb37ea6a4cd019e737955e1748138d251c2de139293a89  models/model.onnx
df38e892ed949f62d0c40978bc666de0b341c5f7921840ae7c72f4df8e8ffa05  models/model.onnx.json
HASHES
./build.command
