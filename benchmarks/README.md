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

Dieser Vergleichspfad startet für jeden Syntheseauftrag einen neuen Pythonprozess und bildet den bisherigen Backend-Ablauf ab. Der Bericht trennt den ersten beobachteten Prozess von den nachfolgenden sequenziellen Prozessen. Die aktuelle App verwendet dagegen nach erfolgreicher Erzeugung einen wiederverwendbaren Worker; dafür steht unten ein eigener Benchmark. Keines der beiden Programme bedient die GUI.

Die System- und Dateicaches werden weder geleert noch kontrolliert. „Erster Lauf“ bedeutet deshalb keinen nachgewiesenen Cold-cache-Start; nachfolgende Läufe belegen kein bereits geladenes Modell.

Gemessen wird ab vor dem Prozessstart bis zum ersten atomar veröffentlichten WAV-Puffer sowie bis zum Prozessende. Die Abfrage erfolgt alle 5 ms und enthält Scheduling-Verzögerungen. Vollständiger Status, Pufferzahl und nichtleere WAV-Header werden geprüft. Exitstatus, Timeout und Fehler werden pro Lauf aufgeführt; jeder fehlerhafte Lauf lässt das Gate mit Exit 1 enden. Median und p95 (Nearest Rank) verwenden ausschließlich erfolgreiche Läufe und geben deren Anzahl an. Bestehende Ausgabedateien werden nicht überschrieben.

Der Bericht enthält Modell-, Konfigurations-, Synthese- und Benchmark-SHA-256, Modellgröße, Python-/Piper-/ONNX-Versionen, Plattform und festen neutralen Testtext. Die Werte schließen weder OCR noch GUI, Audioausgabegerät oder menschlich gehörte Sprache ein. Es gibt keine universelle Latenzschwelle; Leistungsregressionen müssen auf vergleichbarer Hardware und unter vergleichbarer Last bewertet werden.

## Beispielmessung

`measured-installed-2026-09-27.json`: 20/20 erfolgreiche Prozesse, erster beobachteter Puffer 1,151 s; alle Läufe Median 0,899 s / p95 0,957 s. Keine Syntheseänderung wurde dafür installiert. Unterschiede zu früheren Messungen sind keine nachgewiesene Optimierung.

## Wiederverwendetes Modell

```sh
python3 benchmarks/resident.py --python runtime/bin/python3 --worker tts_worker.py \
  --model models/model.onnx --runs 10 --timeout 30 --output benchmark-resident-result.json
```

Diese Messung verwendet den privaten stdin/stdout-Worker. `startup_seconds` umfasst Prozessstart und Laden des Modells bis zur Bereitschaft. `launch_to_first_buffer_seconds` umfasst zusätzlich den ersten Auftrag bis zum sichtbaren WAV-Puffer. `subsequent_requests` misst neue Aufträge nach vollständigem Abschluss des vorherigen im selben Prozess. Die Prozesskennung bleibt dabei gleich. Die RSS-Stichprobe nach den Aufträgen beschreibt den damaligen Prozessspeicher, keinen Peak und keinen reinen Modellverbrauch. Die Ausgabe enthält Versionen, Modell-/Konfigurations-/Worker-/Synthese-/Benchmark-Hashes.

Ein Vergleich ist nur mit gleichem Text, gleicher Stimme und vergleichbarer Last sinnvoll. Die zwei Programme kontrollieren weder Systemcaches noch konkurrierende Prozesse. Ein einzelner besserer Wert ist kein allgemeines Leistungsversprechen. Beide Programme müssen bei fehlendem oder fehlerhaftem Audio fehlschlagen.

`measured-resident-2026-09-27.json`: 20/20 erfolgreiche Aufträge mit vollständiger PCM-Payload-Prüfung; kompletter Prozessstart bis erstem Puffer 1,065 s. Die 19 Folgeaufträge im selben Prozess erreichten Median 0,187 s / p95 0,247 s. RSS-Stichprobe nach den Aufträgen: 164,4 MiB. Diese Werte sind Backend-Messungen auf diesem Mac, keine gemessene Lautsprecher-Latenz.
