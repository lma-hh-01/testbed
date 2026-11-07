# testbed

Lokales Testbed zur Masterarbeit *Sicherheit in Software Supply Chains*.

> Diese README ist noch ein Gerüst. Die vollständige Schritt-für-Schritt-Anleitung folgt, sobald alle Varianten und Szenarien umgesetzt sind.

## Kurzanleitung

Die drei Repositories nebeneinander klonen:

```sh
git clone https://github.com/lma-hh-01/testbed.git
git clone https://github.com/lma-hh-01/example-app.git
git clone https://github.com/lma-hh-01/secure-workflows.git
cd testbed
```

Dann:

```sh
make check-tools          # Werkzeuge prüfen
make cluster VARIANT=v0   # lokale Umgebung aufbauen
make deploy               # Anwendung deployen, danach http://localhost:8080 öffnen
make down                 # alles wieder abbauen
```
