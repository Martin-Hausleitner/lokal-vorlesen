# Einmaliger Anmeldestart — 28.09.2026

`autostart.command` installiert einen benutzerspezifischen LaunchAgent mit `RunAtLoad=true`, Aqua-Sitzung und `/usr/bin/open -g` für das vorhandene installierte Bundle. Keine KeepAlive-, Intervall-, Kalender- oder Dateiwächter-Regel. `install.command` ruft diese Einrichtung nach der Installation auf. `--disable` entlädt und entfernt nur den eigenen Auftrag; `--print` ist rein lesend.

Prüfung am bestehenden installierten Build, ohne Neubau:

- Beide Shellskripte bestehen `zsh -n`; erzeugte und installierte plist bestehen die Strukturprüfung und `plutil`.
- Erstes Laden startete die installierte App tatsächlich. LaunchAgent: `runs=1`, `last exit code=0`, danach `state=not running` (der Starthelfer ist fertig; die App läuft unabhängig weiter).
- Erneutes unverändertes `--enable`: weiterhin `runs=1`, kein erneuter App-Start.
- Reguläres Beenden über Codex Computer Use: nach rund 40 Sekunden weiterhin kein App-Prozess, keine zusätzliche Ausführung des Starthelfers.
- `--disable`: eigene plist entfernt, Auftrag nicht mehr geladen. Anschließendes `--enable` stellte den Auftrag wieder her und startete die App erfolgreich.
- Frische Ereignisse: `selection_shortcut_registered`, `accessibility_trusted`, `ready` am 28.09.2026 um 12:09:03 Wien. OCR-Registrierung ohne protokollierten Fehler; dafür existiert kein separates Erfolgsereignis.
- Reguläres Öffnen über Codex Computer Use bestätigte „Bereit“, 3× und deaktiviertes Stopp. Keine Sprachausgabe oder Aufnahme ausgelöst.
- Strenge Bundle-Signaturprüfung bestanden; beide vorhandenen TCC-Freigaben weiterhin authorization=2 und signature_match=true. Keine Änderung am App-Bundle oder an TCC.

Nicht geprüft: der nächste echte Login und physische Maustastendrücke. Der beobachtete Start durch erstmaliges Laden des LaunchAgents ist getrennt davon zu bewerten. Die vorhandene AutoHide-Logik bleibt unverändert.
