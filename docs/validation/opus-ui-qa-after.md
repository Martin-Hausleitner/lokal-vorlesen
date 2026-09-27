Prüfer: Claude Opus 5.5 (`claude-opus-5-5`), offizieller First-Party-Provider, 27.09.2026. Unabhängige Codeprüfung, keine eigene GUI-Bedienung.

# Opus UI/UX-QA, Nachprüfung: Einstellungs-Popover und Tempo-Menü

Ich habe nur die drei genannten Dateien gelesen. Ich habe nichts geändert, keine GUI bedient und nichts delegiert.

## 1 · Code-Gate: ✅ PASS mit Auflagen

**Der P1-Fehler aus dem Vorher-Gate ist im Code behoben:**
- **Zahnrad → `NSPopover`** statt des 13-teiligen NSMenu (`main.m:576-582`).
  - Transient, 276×302 pt, gruppiert.
  - „Vorlesen/Pause“ und „Beenden“ sind raus.
  - „Ausblenden“ steht mit Abstand in der Fußzeile.
  - Damit gibt es keinen Scroll-Pfeil mehr, und die Verklick-Gefahr bei „Beenden“ ist weg.
- **Bevorzugte Kante hängt vom Modus ab** (`:582`). Wenn der Platz nicht reicht, dreht AppKit die Seite selbst um.
  - Unten-Modus: 88 pt Abstand, 302 pt Höhe.
  - Oben-Modus: 6 pt unter der Menüleiste.
  - Eine falsch gewählte Kante heilt sich dadurch selbst. Ob `NSButton` geflippte Koordinaten hat, spielt deshalb keine Rolle.
- **Mauszugriff zeigt den echten Zustand** (`:571-573`): „aktiv“ ist deaktiviert, „erlauben…“ ist aktiv.
- **Position** (`:537-540`): Das Popover schließt, dann läuft `applyMode:`. Das deckt sich mit eurem CUA-Beleg (Unten gewählt, nach Neuöffnen weiter Unten).
- **Aktionen** (`:520-530`): Jede Aktion schließt zuerst das Popover, dann folgt der Aufruf. Die Tags 0–5 passen zu den Buttons (`:555-574`). Einen Routing-Fehler finde ich nicht.
- **Checkboxen** (`:531-536`): Der Zustand wird nach dem Umschalten aus dem Modell zurückgeschrieben. Das ist robust.
- **Tempo-Menü** (`:421-428`):
  - Bildschirmkoordinaten (`inView:nil`) mit der gemessenen `menu.size`.
  - Oben öffnet es unter dem Button, unten darüber.
  - Beide Seiten werden auf `visibleFrame` begrenzt, mit 8 pt Rand.
  - 11 Einträge passen auf jeden realistischen Bildschirm. Die Rechnung ist schlüssig.
- **Editor** (`:313`, `:335`): `controls` wächst jetzt mit der Breite, das Zahnrad hängt rechts (`MinXMargin`). Damit ist der 108-pt-Streifen weg.
- **Live-Text** (`:413`, `:543` plus Test): Das Panel wird beim Öffnen des Popovers bzw. Tempo-Menüs ausgeblendet. `shouldShowLiveText` blockiert, solange eins davon offen ist. `test-reading-visibility.m:33-39` prüft das und prüft auch, dass der angeheftete Zustand danach zurückkommt. Die Logik ist also abgedeckt.

**Was der Test nicht abdeckt:** Tag-Routing, die Rechnung für die Menü-Position und das Öffnen/Schließen per Zahnrad. Er prüft nur die Sichtbarkeit des Live-Texts, mit Attrappen statt echter Fenster.

## 2 · Visuelles Gate: ⚪ UNVERIFIZIERT (kein FAIL)

- Der CUA-Screenshot erfasst nur das 180×32-Elternfenster. Das Popover ist ein eigenes Fenster und fehlt darauf.
- Das beweist **nicht**, dass die Oberfläche kaputt ist. Es fehlt einfach ein Beleg.
- Die AX-Struktur (alle Buttons und Checkboxen, Segment-Beschriftungen, Unten bleibt gespeichert) stützt den Code-Befund.
- Offen bleiben die Tests A–C aus dem Vorher-Gate: Lage des Popovers zu Notch und Dock, alle 11 Tempowerte ohne Scroll-Pfeil in beiden Modi.
- Nachweis-Idee: ein Screenshot vom ganzen Bildschirm oder vom Popover-Fenster.
- Ohne Hardware-Maus gibt es keine echte Hardware-E2E. Das ist korrekt ausgewiesen.

## 3 · Verbleibende Befunde (max. 3, beide P2, nicht bestätigt)

**P2-1 · Zweiter Zahnrad-Klick öffnet das Popover womöglich gleich wieder** (`main.m:542`, `:577`)
- Ein transientes Popover schließt schon beim Mausdruck außerhalb, und dazu zählt auch das Zahnrad.
- Die Button-Aktion kommt erst beim Loslassen. Dann ist `shown` schon `NO`, und `:542` öffnet das Popover neu.
- Das ist ein bekanntes AppKit-Muster; Test D („zweiter Klick schließt“) ist nicht belegt.
- Kleiner Fix: den Schließzeitpunkt über `popoverDidClose:` merken und einen erneuten Aufruf innerhalb von ca. 0,3 s ignorieren.

**P2-2 · Tastatur, Esc und Klick nach außen im nicht aktivierten Panel** (`main.m:581`)
- `makeKeyWindow` wirkt nur, wenn das Panel `canBecomeKeyWindow` erfüllt. Das steht nicht im gelieferten Ausschnitt und ist deshalb nicht bewertbar.
- Ist die App nicht aktiv, kann Folgendes ausbleiben:
  - Tab, Leertaste und Esc im Popover;
  - das Schließen des transienten Popovers bei einem Klick in eine **andere App**.
- Beide Punkte (Test E und die zweite Hälfte von Test D) sind unbelegt.
- Nicht auf Verdacht umbauen. Erst einmal per CUA prüfen:
  - Esc drücken, wenn das Popover offen ist.
  - In den Finder klicken, wenn das Popover offen ist.
- Scheitert das, reicht ein gezieltes Aktivieren der App nur beim Öffnen des Popovers.

**Weitere Befunde:** keine. Die Menü-Position, das Aktions-Routing und die Unterdrückung des Live-Texts sind im Code korrekt. Einen Umbau braucht es nicht.

## 4 · Urteil

- **Code:** PASS. Das abgeschnittene NSMenu ist ursächlich beseitigt, und ich sehe keinen neuen P1-Fehler.
- **Optik:** UNVERIFIZIERT, solange es keinen Screenshot mit dem Popover-Fenster gibt.
- **Freigabe:** empfohlen, sobald P2-1 und P2-2 per CUA gegengeprüft sind. Beides sind Interaktionstests, kein Code-Umbau.

