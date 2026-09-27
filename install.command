#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
SOURCE="$PWD/Lokal vorlesen.app"
DEST="$HOME/Applications/Lokal vorlesen.app"
[[ -d "$SOURCE" ]] || ./build.command
if [[ -e "$DEST" ]]; then
  if /usr/bin/pgrep -f "$DEST/Contents/MacOS/LokalVorlesen" >/dev/null; then
    printf 'Bitte zuerst Lokal vorlesen beenden; die laufende App bleibt unverändert.\n' >&2
    exit 1
  fi
  BACKUP="$HOME/Applications/Lokal vorlesen.backup-$(date +%Y%m%d-%H%M%S)"
  /bin/mv "$DEST" "$BACKUP"
  printf 'Bisherige App gesichert: %s\n' "$BACKUP"
fi
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$SOURCE" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
printf 'Installiert: %s\nApp öffnen, danach Text markieren > Rechtsklick > Dienste > Generate Audio.\n' "$DEST"
