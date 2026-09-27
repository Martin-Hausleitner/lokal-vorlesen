# Opus UI/UX Quality Gate — vorher

# Opus UI/UX-Gate: LokalVorlesen, Einstellungs-Popup

## 1 · Ergebnis: ❌ FAIL

**Was der Screenshot zeigt (Fakten):**
- Ein natives NSMenu mit einem **Scroll-Pfeil ⌃ oben**.
- Sichtbar sind nur die **letzten 4 Einträge**: „Stimmen & Modelle…“, „Mauszugriff aktivieren…“ (markiert), „Player ausblenden“ und „Beenden“ (mit einem von macOS automatisch gesetzten Icon).
- Der Player selbst ist nicht zu sehen. Ob das Menü am Player verankert ist, lässt sich aus dem Bild also nicht beweisen.

**Was die Quelle dazu sagt:** `showSettings` (`main.m:501-527`) baut **13 Einträge und 3 Trenner**. Versteckt bleiben damit Status, Stimme, Vorlesen/Pause, Bereich vorlesen, Zwischenablage, Auto-Kopieren, Editor, Lesetext, Oben/Unten. Das sind **9 von 13 Funktionen** – darunter genau die Position, um die es im Test geht.

**Ursache (Fakt):** `popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,0) inView:self.settingsButton` (`main.m:527`). Der Ankerpunkt ist eine feste Ecke des 24×24-Buttons. Er passt sich nicht an den Modus an: Das Menü klappt nicht nach oben, wenn der Player unten steht. Im Unten-Modus steht der Player nur **88 pt über `visibleFrame.minY`** (`main.m:546`). Dann reicht der Platz nicht und AppKit kürzt das Menü mit Scroll-Pfeilen. Dass genau das im Screenshot passiert ist, ist eine plausible Hypothese; der Modus ist im Bild nicht sichtbar.

## 2 · Probleme nach Priorität

1. **Menü abgeschnitten, Kernfunktionen nicht erreichbar.**
   - Fakt: Screenshot und `main.m:527`.
   - Folge: Wer Position oder Auto-Vorlesen sucht, sieht nur „Beenden“ und muss den Scroll-Pfeil erst entdecken. So ist die Einstellung nicht benutzbar.

2. **Menü überladen und doppelt.**
   - Fakt: „Vorlesen / Pause“ (`:510`) wiederholt den Play-Button. Status und Stimme (`:504-508`) sind deaktivierte Info-Zeilen, die Platz kosten. Aktionen, Einstellungen und App-Beenden stehen in einer Liste.
   - Folge: Das Menü ist zu hoch und schwer zu überblicken. Genau diese Höhe verursacht Problem 1.

3. **„Beenden“ direkt unter „Player ausblenden“, ohne Trenner.**
   - Fakt: `:525-526`.
   - Folge: Ein Verklicken beendet die App und damit den residenten Worker. Das ist ein echtes Risiko.

4. **„Mauszugriff aktivieren…“ steht immer gleich da.**
   - Fakt: Der Titel ist fest (`:524`). Nur `permissionButton` wechselt je nach Zustand (`:677, :687`).
   - Folge: Die Zeile wirkt auch bei erteiltem Zugriff wie ein offener Fehler. Ob Nutzer das so wahrnehmen, ist eine Hypothese.

5. **Tempo-Menü und erweiterter Editor haben dasselbe Muster bzw. eigene Layoutfehler.**
   - `showSpeed` (`:416`) nutzt denselben Anker `NSZeroPoint` bei 11 Einträgen. Im Unten-Modus droht vermutlich derselbe Abschnitt (Hypothese, kein Screenshot).
   - Im Editor bleibt `controls` 180 pt breit (`:310`, nur `NSViewMinYMargin`). Bei 288 pt Fensterbreite sitzt das Zahnrad bei x=149 statt am rechten Rand, rechts bleibt ein leerer Streifen von 108 pt (Fakt aus dem Code, Optik ist Hypothese).
   - Nebenbefunde:
     - Beim Hover erscheint unter dem Player im Oben-Modus ein Live-Text-Panel von 320×106 pt (`:378-380, :465`), genau dort, wo das Menü aufklappt.
     - „Oben an der Notch“ heißt eigentlich: 6 pt unter der Menüleiste auf `NSScreen.mainScreen` (`:543-546`). Bei mehreren Displays kann das der falsche Bildschirm sein (Hypothese).

## 3 · Kleinste stimmige AppKit-Lösung

**Zahnrad → `NSPopover`** statt des 13-teiligen NSMenu:
- `behavior = NSPopoverBehaviorTransient`.
- `showRelativeToRect:settingsButton.bounds ofView:settingsButton preferredEdge:` mit `NSRectEdgeMinY` im Oben-Modus und `NSRectEdgeMaxY` im Unten-Modus. AppKit dreht bei Platzmangel selbst um.
- Inhalt ca. 260×200 pt, gruppiert:
  - **Kopfzeile:** Status · Stimme, eine Zeile, sekundäre Schrift.
  - **Vorlesen:** Knöpfe „Bereich…“ und „Zwischenablage“, dazu die Checkboxen „Kopiertes automatisch“ und „Lesetext anheften“.
  - **Position:** `NSSegmentedControl` Oben/Unten. `modeControl` und `changeMode:` gibt es schon (`:558`).
  - **Fußzeile:** „Stimmen & Modelle…“ und „Mauszugriff“ mit Zustand (✓ aktiv / aktivieren…).
- Entfernen: „Vorlesen / Pause“ (dafür gibt es den Play-Button) und „Beenden“ (bleibt im App-Menü mit ⌘Q, `:656`, und im Status-Item, `:671`). „Player ausblenden“ kommt in die Fußzeile, mit Abstand.
- **Tempo:** Das NSMenu bleibt, aber mit `positioningItem:` = aktuell gewählter Wert und passendem Anker am Button. So verhält es sich wie ein natives Popup und liegt über dem Button statt darunter.
- **Editor:** `controls` bekommt `NSViewWidthSizable`, das Zahnrad `NSViewMinXMargin`, damit es rechts bleibt.
- Unverändert bleiben: Player 180×32, Editor 288×142, Engine und Worker.
- Risiko: Das Popover sitzt an einem `NonactivatingPanel`. Die Tastatur funktioniert nur, wenn das Panel `canBecomeKeyWindow` erfüllt. Das muss geprüft werden.

## 4 · Visuelle Abnahmetests (echte Screenshots, im Repo eingebettet)

**A · Oben/Notch (Notch-MacBook, eingebautes Display)**
- Das Popover öffnet sich unter dem Zahnrad, der Pfeil zeigt aufs Zahnrad.
- **Alle** Gruppen sind ohne Scroll-Pfeil sichtbar.
- Das Popover überdeckt weder Menüleiste noch Notch.

**B · Unten**
- Das Popover öffnet sich **über** dem Player, vollständig und ohne Scroll-Pfeil.
- Es überdeckt das Dock nicht.
- Dasselbe mit ausgeblendetem Dock und mit Dock links.

**C · Tempo-Menü in beiden Modi**
- Alle 11 Werte sind ohne Scroll-Pfeil sichtbar.
- Der aktuelle Wert trägt ✓ und liegt über dem Button.
- Nach Auswahl zeigt das Label den neuen Wert, und dieser Wert ist nach einem Neustart noch da.

**D · Öffnen und Schließen**
- Klick aufs Zahnrad öffnet, ein zweiter Klick schließt.
- Esc schließt, ebenso ein Klick außerhalb.
- Beim Moduswechsel schließt das Popover und der Player springt an die neue Position.
- Das Hover-Live-Text-Panel liegt nie über dem offenen Popover.

**E · Tastatur**
- Mit Tab erreicht man jedes Bedienelement im Popover; Leertaste schaltet Checkboxen.
- ⌘↩ startet und pausiert.
- Im Editor steht der Cursor sofort im Textfeld, und ⌘V fügt ein.
- VoiceOver liest „Einstellungen“, „Start“, „Stopp“ und „Tempo wählen“ vor.

**F · Wiedergabe**
- Im Leerlauf ist der Player genau 180×32 (Screenshot mit Maß).
- Start: Pegel animiert sich und die Stopp-Taste wird aktiv.
- Pause und Fortsetzen funktionieren; Stopp setzt auf Start zurück.
- Die Tempogrenzen 0,5× und 4× werden eingehalten.
- Im erweiterten Editor (288×142) sitzt das Zahnrad am rechten Rand.

**G · Nachweis**
- Pro Test ein echter Screenshot, datiert in `.proof/`, und keine Fehler- oder Scroll-Pfeil-Zustände.
- Damit ist nur das getestete Gerät und Display belegt, keine „alle Hardware“-E2E.


Prüfer: Claude Opus, tatsächliches Modell `claude-opus-5-5`, Anbieter `firstParty`; 27.09.2026. Nutzerbeauftragtes Nur-Lese-Gutachten.
