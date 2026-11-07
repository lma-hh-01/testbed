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

## Auf dem eigenen GitHub-Account ausprobieren (Forks)

> Die ausführliche Anleitung folgt. Schon jetzt fest steht, was nach dem Forken der drei Repositories nötig ist:

- In jedem Fork unter „Actions“ die Workflows aktivieren (in Forks sind sie zunächst ausgeschaltet).
- Die [Renovate-App](https://github.com/apps/renovate) für die Forks von `example-app` und `secure-workflows` installieren („Only select repositories“). Renovate hält die gepinnten Abhängigkeiten von Variante V3 aktuell.
- Account-Namen und E-Mail-Adresse in den Forks anpassen (dafür wird es einen eigenen Befehl geben).
