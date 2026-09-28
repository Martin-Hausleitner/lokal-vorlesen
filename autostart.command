#!/bin/zsh
set -euo pipefail

LABEL="local.codex.lokalvorlesen.login"
APP_PATH="$HOME/Applications/Lokal vorlesen.app"
AGENT_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
MODE="${1:---enable}"

make_plist() {
  python3 - "$APP_PATH" "$LABEL" <<'PY'
import plistlib, sys
plistlib.dump({
    'Label': sys.argv[2],
    'ProgramArguments': ['/usr/bin/open', '-g', sys.argv[1]],
    'RunAtLoad': True,
    'LimitLoadToSessionType': 'Aqua',
}, sys.stdout.buffer)
PY
}

case "$MODE" in
  --print) make_plist; exit 0 ;;
  --disable)
    if /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      /bin/launchctl bootout "$DOMAIN/$LABEL"
    fi
    /bin/rm -f "$AGENT_PATH"
    printf 'Autostart entfernt. Eine bereits geöffnete App bleibt geöffnet.\n'
    exit 0 ;;
  --enable) ;;
  *) printf 'Verwendung: %s [--enable|--disable|--print]\n' "$0" >&2; exit 2 ;;
esac

[[ -d "$APP_PATH" ]] || { printf 'Zuerst die App installieren: %s\n' "$APP_PATH" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
/bin/mkdir -p "${AGENT_PATH:h}"
AGENT_TMP=$(mktemp "${AGENT_PATH}.XXXXXX")
trap '/bin/rm -f "$AGENT_TMP"' EXIT
make_plist > "$AGENT_TMP"
/usr/bin/plutil -lint "$AGENT_TMP"
/bin/chmod 600 "$AGENT_TMP"
if [[ -f "$AGENT_PATH" ]] && /usr/bin/cmp -s "$AGENT_TMP" "$AGENT_PATH"; then
  /bin/rm -f "$AGENT_TMP"
else
  if /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    /bin/launchctl bootout "$DOMAIN/$LABEL"
  fi
  /bin/mv "$AGENT_TMP" "$AGENT_PATH"
fi
# No KeepAlive, interval or kickstart: manual quitting stays respected.
/bin/launchctl enable "$DOMAIN/$LABEL"
if ! /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  /bin/launchctl bootstrap "$DOMAIN" "$AGENT_PATH"
fi
printf 'Einmaliger Start bei Anmeldung eingerichtet; kein automatischer Neustart nach Beenden.\n'
