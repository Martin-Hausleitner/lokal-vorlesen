# Ausfallsicherheit — 27.09.2026

Geprüft wurden gezielte Fehlerfälle und 50 aufeinanderfolgende lokale Syntheseaufträge. Die Tests ersetzen keine physischen Maustastendrücke oder eine akustische Beurteilung.

- Pufferstillstand vor und nach Wiedergabebeginn; Wiederanlauf-Sperrzeit und maximal ein Wiederholungsversuch.
- Kein erneutes Vorlesen, wenn das Audio schon fertig ist, aber der Prozessabschluss fehlt.
- Echter SIGTERM-ignorierender Galerieprozess: Beenden nach etwa 2,1 Sekunden.
- Echter SIGTERM-ignorierender Sprachprozess: Pufferwächter bleibt bedienbar, Prozess und verspäteter Callback werden bereinigt.
- Fünf echte Prozess-/Protokollfehler sowie eine veraltete Abschlussmeldung während eines Folgeauftrags.
- Abgebrochene, zu kurze und checksum-fehlerhafte Downloads; Auswahlkonflikt; Beenden während Download/Validierung; erfolgreiche Wiederholung. Diese Downloadtests verwenden lokale Ersatzobjekte, keine Netzwerkanfragen.
- 50/50 Syntheseaufträge mit vollständigen PCM-Daten bestanden. Erster beobachteter Prozess: 1,325 Sekunden bis zum ersten Puffer. 49 Folgeaufträge: Median 0,204 Sekunden, p95 0,247 Sekunden. Keine kontrollierte Kaltcache- oder Lautsprechermessung.

Nachweise: [Testprotokoll](reliability-tests-20260927.txt), [50er-Messung](resident-50-20260927.json).
