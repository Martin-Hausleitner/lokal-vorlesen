#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/Lokal vorlesen.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=13.0 src/main.m src/OCRSelection.m src/LVAudioPlayer.m src/LVSpeechWorker.m -framework Cocoa -framework AVFoundation -framework Carbon -framework ApplicationServices -framework WebKit -framework Vision -framework ScreenCaptureKit -o "$APP/Contents/MacOS/LokalVorlesen"
cp Info.plist "$APP/Contents/Info.plist"
cp synthesize.py models/model.onnx models/model.onnx.json "$APP/Contents/Resources/"
cp tts_worker.py voice_server.py "$APP/Contents/Resources/"
if [[ -f voices.json && -f web/index.html ]]; then
  cp voices.json "$APP/Contents/Resources/"
  mkdir -p "$APP/Contents/Resources/web"
  cp web/index.html "$APP/Contents/Resources/web/"
fi
[[ ! -L "$APP/Contents/Resources/tts-runtime" ]] || rm "$APP/Contents/Resources/tts-runtime"
print -r -- "$PWD/runtime/bin/python3" > "$APP/Contents/Resources/runtime-path.txt"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
printf 'Fertig: %s\n' "$APP"
