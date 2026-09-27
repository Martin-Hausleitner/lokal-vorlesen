# Generate Audio – lokal auf dem Mac

Kleine lokale Sprachausgabe für macOS: 180 × 32 Pixel, deutsche Standardstimme, gepufferte Erzeugung, lokale OCR und eine Galerie mit 100 fertigen Hörproben.

## Schnellstart

Voraussetzungen: Apple Silicon (hier geprüft), aktuelle Xcode Command Line Tools, `uv`; macOS 13 oder neuer für den Player und **macOS 15.2 oder neuer für OCR**.

```sh
git clone https://github.com/Martin-Hausleitner/lokal-vorlesen.git
cd lokal-vorlesen
./setup.command
./install.command
open "$HOME/Applications/Lokal vorlesen.app"
```

Die Einrichtung lädt das Modell mit geprüfter SHA-256-Prüfsumme und die festgeschriebene Python-Laufzeit. Für Textzugriff und OCR müssen die entsprechenden macOS-Freigaben der installierten App gültig sein. Nach einem selbst signierten Neubau kann eine erneute Freigabe nötig sein.

Dies ist ein lokales Open-Source-Projekt, kein notarisiertes App-Store-Paket.

## Bedienung

- Text markieren und **Rechtsklick → Dienste → Generate Audio** wählen.
- Mit freigegebener Bedienungshilfe kann die App lesbaren Text am Mauszeiger erfassen und eine eigene **Generate Audio**-Schaltfläche anbieten. Fremde Kontextmenüs bleiben erhalten.
- Die schwarze **180 × 32 Pixel** große Leiste zeigt nur Start/Pause, Stopp, anklickbares Tempo und einen kleinen Audiopegel. Das Tempo von **0,5× bis 4×** bleibt gespeichert. Auf dem Tempo scrollen ändert es in Viertelschritten; Klick öffnet die Auswahl. Scrollen daneben spult innerhalb der bereits erzeugten Audiopuffer vor oder zurück. Beim Darüberfahren erscheinen Zahnrad und der gerade gesprochene Textabschnitt. Die Textanzeige folgt den Audiopuffern, nicht einzelnen wortgenauen Zeitmarken.
- Im Zahnrad-Menü **Oben an der Notch / Unten über Aqua** wählen. Der Pegel reagiert auf das abgespielte Audio.
- **⌘E** oder **App-Menü → Textfeld ein-/ausblenden** klappt das Eingabefeld auf und wieder zu, auch ohne Hover. **Zahnrad → Text eingeben** bietet denselben Weg. **Stimmen & Modelle** öffnet die lokale Hörproben-Galerie in einem eigenen App-Fenster. Alternativ **⌘,** drücken.
- **⌃⌥⌘K** liest die aktuelle Markierung direkt über Bedienungshilfen, ohne Kopieren und ohne vorherigen Fokuswechsel. Die hintere Maustaste wird im Aqua-/OpenLogi-Chat auf diesen Shortcut abgestimmt.
- **⌃⌥⌘O** startet die Bereichsauswahl: Rechteck ziehen, loslassen, lokal per Apple Vision erkennen und vorlesen. Escape bricht ab. Bei fehlender Markierung öffnet **⌃⌥⌘K** ebenfalls die Bereichsauswahl. Bildschirmaufnahme muss für die App erlaubt sein. Bilder werden nicht hochgeladen oder dauerhaft gespeichert.
- Als separater Weg Text kopieren und **⌃⌥⌘L** drücken. Im Zahnrad kann **Kopiertes automatisch vorlesen** eingeschaltet werden; standardmäßig ist es aus. Das liest neue Textkopien, ohne die Zwischenablage zu verändern. Von Apps als vertraulich markierte Kopien werden dabei übersprungen.
- Logitech-Zielbelegung: vorne Aqua mit Enter nach Einfügung, hinten kurz Markierung/OCR-Fallback, hinten lang OCR-Bereich. Die Konfiguration wird mit dem Aqua-Chat abgestimmt. Die tatsächlichen Mauskanten und das Ziehen mit gehaltenem hinteren Knopf sind erst nach einem Hardwaretest bestätigt; normales Ziehen mit links bleibt der Auswahlweg.

Die Erzeugung erfolgt gepuffert in Abschnitten: Der erste Abschnitt spielt bereits, während die nächsten berechnet werden. Im Test standen 38 Sekunden Sprache in 13 Puffern bereit; der erste nach 1,115 Sekunden, alle nach 3,87 Sekunden. Tempoänderungen benötigen keine erneute Erzeugung. Die Schaltfläche am Mauszeiger ist eine eigene Ergänzung; macOS erlaubt keinen allgemeinen zusätzlichen Eintrag in jedem fremden Kontextmenü. Nur Text, den die jeweilige App über ihre Bedienungshilfen bereitstellt, kann dort erfasst werden. Bilder, geschützte Eingaben und manche Zeichenflächen sind damit nicht abgedeckt.

## Modell und Installation

- **Modell:** Piper `de_DE-thorsten-low` INT8, **18.555.534 Byte (18,6 MB)**, Deutsch, 16 kHz, ein Sprecher. Die quantisierte Variante ist etwa 71 % kleiner als das ursprüngliche Modell.
- **Laufzeit:** Piper 1.8.0 / ONNX Runtime auf Apple Silicon, ca. 148 MiB zusätzlich zum Modell. Kein PyTorch und kein Cloud-Dienst.
- Die vorhandene Python-3.12-Installation des Macs wird verwendet. Das App-Bundle verweist auf den `runtime`-Ordner dieses Projekts; den Ordner daher nicht verschieben oder löschen.
- `setup.command` installiert die festgeschriebenen Abhängigkeiten, prüft die Modell-Prüfsummen und baut die App. Nur die Einrichtung benötigt Internet.
- `build.command` baut die App erneut; `install.command` installiert sie in den Programme-Ordner des Benutzers.

Text geht über eine private Standardeingabe an einen lokalen Prozess. Nach abgeschlossener Erzeugung bleibt höchstens eine Stimme für weitere Aufträge geladen; nach fünf Minuten ohne Auftrag beendet sich der Prozess und gibt seinen Speicher frei. Ein Stimmenwechsel oder der Abbruch einer noch laufenden Erzeugung verwirft den Prozess. Bereits fertig erzeugtes Audio lässt sich stoppen, ohne das geladene Modell zu verlieren. Die erzeugte WAV-Datei ist temporär. Es werden keine Texte an einen Server gesendet. Die zerlegte Lautdarstellung `c` plus Cedille wird für den deutschen „ich“-Laut in das vom Modell erwartete `ç` umgewandelt.

## Stimmen-Galerie

Die Galerie bietet **100 fertige Hörproben**, davon neun deutsche Optionen, inklusive Thorsten High. Die App startet die Galerie ausschließlich auf `127.0.0.1:8769`. Hörproben sind veröffentlichte Beispielaufnahmen; dafür ist Internet nötig. **Im Player verwenden** lädt nur das ausgewählte Modell, prüft es und übernimmt es für das nächste Vorlesen. Bereits erzeugtes Audio läuft mit seiner bisherigen Stimme weiter. Der Standard Thorsten INT8 bleibt ohne zusätzlichen Download verfügbar. Die unterstützte lokale Spracherzeugung benötigt nach dem Modelldownload kein Internet. **96 Optionen sind zur lokalen Auswahl freigegeben; vier sind ausdrücklich nur Hörproben:** Japanisch, Litauisch, Thailändisch und die chinesische Stimme Chaowen benötigen zusätzliche oder neuere Sprachunterstützung. Für Chinesisch steht Huayan zur lokalen Auswahl bereit. Hebräische Lautumwandlung wurde mit dem vorhandenen Paket geprüft. Arabisch verwendet keine automatisch nachgeladene Vokalisierung; dies kann die Aussprache unvokalisierter Texte beeinträchtigen. Nicht alle 96 Modelle wurden heruntergeladen und vollständig synthetisiert.

Stimmwahl und Playerposition werden im benutzerspezifischen Application-Support-Ordner gespeichert. Ein Wechsel während eines Downloads wird abgewehrt. Fremde Origins und Hostnamen sowie unbekannte Stimmenkennungen dürfen die Auswahl nicht ändern.

## Ressourcen und Wiederanlauf

Die wiederverwendete Sprachengine benötigt zusätzlichen Arbeitsspeicher, solange sie bereitsteht. Im lokalen Backend-Test lag die RSS-Stichprobe bei etwa 164–183 MiB einschließlich Python, Sprachverarbeitung und Modell; das ist kein garantierter Höchstwert. Nach fünf Minuten ohne Syntheseauftrag endet sie automatisch.

Die aktive Erzeugung/Wiedergabe wird als zeitkritische Nutzeraktivität angemeldet; der Syntheseprozess verwendet User-Initiated-QoS. Es werden keine globalen Systemeinstellungen oder fremden Prozesse verändert.

Wenn vor dem ersten Audiopuffer 30 Sekunden lang keine Ausgabe startet, wird ausschließlich dieser Syntheseauftrag einmal neu gestartet. Zwischen automatischen Versuchen liegen mindestens 120 Sekunden. Hängt auch der Wiederholungsversuch, wird der Auftrag beendet. Laufendes oder pausiertes Audio und eine OCR-Auswahl werden nicht dafür abgebrochen. Ein beendeter Galerieprozess darf höchstens dreimal pro App-Sitzung mit jeweils mindestens 60 Sekunden Abstand neu starten. Ein blockierter macOS-Hauptthread oder ein Hardwarefehler wird damit nicht vollständig überwacht.

## Entwicklung

Der wiederverwendete Worker wird nur für den nativen Player eingesetzt. Der bisherige CLI-Aufruf bleibt als separat messbarer Vergleichspfad erhalten. Bei einem Abbruch während der Erzeugung wird der Worker beendet; nach abgeschlossener Erzeugung kann derselbe Prozess den nächsten Auftrag übernehmen.

```sh
./build.command
./tests/run.command
```

Reproduzierbare Laufzeitmessungen: [Benchmark-Anleitung](benchmarks/README.md). Sie trennt den ersten beobachteten Prozess von nachfolgenden Prozessen und dokumentiert Cache- und Messgrenzen.

## Quellen und Lizenzen

Der eigene Quellcode steht unter **GPL-3.0**; siehe `LICENSE`. Stimmen und Fremdkomponenten behalten ihre jeweiligen Lizenzen.

- [Piper](https://github.com/OHF-Voice/piper1-gpl), GPL-3.0; Lizenzkopie unter `licenses/`.
- [Thorsten Low Modell](https://huggingface.co/rhasspy/piper-voices/tree/main/de/de_DE/thorsten/low); die Modellkarte nennt CC0 für den Datensatz.
- [Offizielle INT8-Version](https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-thorsten-low-int8.tar.bz2) aus den sherpa-onnx-Modellveröffentlichungen; funktioniert hier direkt mit Piper.
- [Thorsten Voice](https://github.com/thorstenMueller/Thorsten-Voice).

## Prüfung

Die lokale Synthese wurde mit durch macOS gesperrtem Netzwerk erfolgreich ausgeführt. Leere Eingaben, überlange Eingaben und Überschreiben vorhandener Audiodateien werden abgewehrt. Die Messungen sind Einzelmessungen auf diesem Mac, keine allgemeinen Leistungsversprechen.

Der native 4×-Audiopfad wurde praktisch geprüft: 9,424 Sekunden Quelle liefen in 2,559 Sekunden bis zum Abschluss. Die Tests sichern Pufferpause, verspätete OCR-Ergebnisse, begrenzten Wiederanlauf, Spulen im vorhandenen Player und verspätete Generierungsabschlüsse. Hinzu kommen sieben Benchmarktests, sechs Python-Worker-Tests und ein nativer Integrationstest mit echtem Modell für Prozesswiederverwendung, Stimmenabgrenzung, Abbruch und erzwungenes Beenden eines SIGTERM-ignorierenden Testprozesses.

Am 27. September 2026 über Codex Computer Use geprüft: 180 × 32 Pixel großer Player, Texteingabe und Wiedergabe, Tempoänderung durch Scrollen, Stimmen-Galerie, Thorsten-Hörprobe sowie Download und Auswahl von Eva K. Beim aktuellen GUI-Test startete der erste Audiopuffer nach 1,413 Sekunden. Bedienungshilfe wurde nach Erneuerung ihrer Signaturbindung von der App als gültig erkannt. Die OCR-Auswahl öffnet sich mit Bildschirmaufnahme-Freigabe; Escape beendet sie.

Ein anschließender unabhängiger Computer-Use-Test bestätigte Bildschirmbereich → Apple-Vision-Texterkennung → Player-Wiedergabe bis zum Abschluss. Der erste Audiopuffer startete 1,081 Sekunden nach dem Syntheseauftrag. Dafür musste das Testtextfenster tatsächlich in den Vordergrund gebracht werden; eine isolierte App-Aufnahme allein garantiert das nicht. Menschlich gehörte Ausgabe ist damit nicht belegt.

Die spätere Bedienprüfung bestätigte außerdem die Auswahl von 4×, Wechsel in den pausierten Zustand mit Fortsetzen-Schaltfläche, Stopp sowie Scroll-Spulen außerhalb des Tempoelements (GUI-Ereignis `seeked`). Noch nicht vollständig praktisch bestätigt: Hover-Textanzeige sowie die echten kurzen und langen Logitech-Maustastendrücke. Erfolgreiche Synthese allein belegt keinen appübergreifenden Rechtsklick-Ablauf und keine subjektive Stimmqualität.

### Wiederverwendung im installierten Player

Am 27.09.2026 lief derselbe neutrale Testtext zweimal im sichtbaren Player: erster Puffer nach 1,199 s beim ersten Auftrag und nach 0,302 s beim Folgeauftrag. Beide Aufträge endeten erfolgreich und verwendeten nachweislich dieselbe Worker-Prozesskennung. Ein weiterer Lauf bestätigte Pause und Stopp. ⌘E klappte das Textfeld ein; der Menüpunkt öffnete es wieder. Die strenge Code-Signaturprüfung bestand auch nach der Wiedergabe. Die Angaben beschreiben den Player-Audiopfad, keine durch ein Mikrofon gemessene Lautsprecher-Latenz.
