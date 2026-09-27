# Reproduzierbarer Backend-Benchmark

Vom Repository aus nach `setup.command`:

```sh
python3 benchmarks/run.py --python runtime/bin/python3 --script synthesize.py \
  --model models/model.onnx --runs 20 --timeout 30 --output benchmark-result.json
```

Für die tatsächlich installierten Ressourcen:

```sh
APP="$HOME/Applications/Lokal vorlesen.app/Contents/Resources"
python3 benchmarks/run.py --python "$(cat "$APP/runtime-path.txt")" \
  --script "$APP/synthesize.py" --model "$APP/model.onnx" \
  --runs 20 --timeout 30 --output benchmark-installed-result.json
```

Die aktuelle App startet für jeden Syntheseauftrag einen neuen Pythonprozess. Es gibt keinen residenten Warmmodell-Dienst. Deshalb trennt der Bericht den ersten beobachteten Prozess von den nachfolgenden sequenziellen Prozessen. Auch bei bereits laufender App lädt jeder neue Auftrag das Modell neu. Der Benchmark bedient die App nicht und misst keine warme GUI-Sequenz; er bildet deren Backend-Prozessstart ab.

Die System- und Dateicaches werden weder geleert noch kontrolliert. „Erster Lauf“ bedeutet deshalb keinen nachgewiesenen Cold-cache-Start; nachfolgende Läufe belegen kein bereits geladenes Modell.

Gemessen wird ab vor dem Prozessstart bis zum ersten atomar veröffentlichten WAV-Puffer sowie bis zum Prozessende. Die Abfrage erfolgt alle 5 ms und enthält Scheduling-Verzögerungen. Vollständiger Status, Pufferzahl und nichtleere WAV-Header werden geprüft. Exitstatus, Timeout und Fehler werden pro Lauf aufgeführt; jeder fehlerhafte Lauf lässt das Gate mit Exit 1 enden. Median und p95 (Nearest Rank) verwenden ausschließlich erfolgreiche Läufe und geben deren Anzahl an. Bestehende Ausgabedateien werden nicht überschrieben.

Der Bericht enthält Modell-, Konfigurations-, Synthese- und Benchmark-SHA-256, Modellgröße, Python-/Piper-/ONNX-Versionen, Plattform und festen neutralen Testtext. Die Werte schließen weder OCR noch GUI, Audioausgabegerät oder menschlich gehörte Sprache ein. Es gibt keine universelle Latenzschwelle; Leistungsregressionen müssen auf vergleichbarer Hardware und unter vergleichbarer Last bewertet werden.

## Beispielmessung

`measured-installed-2026-09-27.json`: 20/20 erfolgreiche Prozesse, erster beobachteter Puffer 1,151 s; alle Läufe Median 0,899 s / p95 0,957 s. Keine Syntheseänderung wurde dafür installiert. Unterschiede zu früheren Messungen sind keine nachgewiesene Optimierung.
