# testbed

Lokales Testbed.

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

## Angriffsszenarien

Jedes Szenario spielt einen Angriff aus dem Bedrohungsmodell gegen die gerade laufende Variante durch und hält das Ergebnis fest. So wird sichtbar, ab welcher Variante ein Angriff abgewehrt wird.

```sh
make cluster VARIANT=v1     # Variante aufbauen, gegen die geprüft wird
make scenario AK=13         # Szenario ausführen
```

Das Ergebnis jedes Szenarios ist eines von:

- **durchgelassen** – der Angriff war erfolgreich, das Image läuft im Cluster,
- **admission-abgelehnt** – die Prüfung an der Admission hat das Deployment abgelehnt,
- **build-abgebrochen** – schon die Pipeline hat den Angriff gestoppt, es entstand kein Image,
- **rbac-verweigert** – die Rechtevergabe im Cluster hat die Aktion verhindert.

Die Ergebnisse werden als Tabelle angezeigt und in `.work/szenarien.csv` geschrieben (anderer Ort mit `make scenario AK=.. RESULTS=results/szenarien.csv`). Jede Zeile nennt Variante, Szenario, erwartetes und tatsächliches Ergebnis.

### Lokale Szenarien

Diese laufen vollständig auf dem Rechner, ohne GitHub. Ein frisch gebautes oder verändertes Image wird direkt in die lokale Registry gelegt und als eingeschränkter Deployer deployt.

| Befehl | Angriff | Erwartet | Woran erkennbar |
|---|---|---|---|
| `make scenario AK=07` | Image außerhalb der Pipeline gebaut und direkt in die Registry gelegt | ab V1 abgelehnt (Signatur der Pipeline fehlt) | Ergebnis `admission-abgelehnt`, Meldung „nicht signiert“ |
| `make scenario AK=08` | signiertes Image verändert, Original-Signatur umgehängt | ab V1 abgelehnt (Signatur deckt den neuen Digest nicht) | `admission-abgelehnt`, Digest-Bindung |
| `make scenario AK=09` | Tag in der Registry auf ein untergeschobenes Image umgehängt | ab V1 abgelehnt (Digest-Pflicht) | `admission-abgelehnt`, „does not have a digest“ |
| `make scenario AK=10b` | fremdes Image unter vertipptem Namen (`ngnix`) | ab V1 abgelehnt (Signatur fehlt) | `admission-abgelehnt` |
| `make scenario AK=12` | Deployer versucht, die Verifikation zu ändern (Richtlinie, Webhook, Rechte) | in allen Varianten verweigert (RBAC) | `rbac-verweigert` je Teil-Angriff |
| `make scenario AK=13` | unsigniertes Image per Pod/Deployment/Job/CronJob und in fremdem Namespace | ab V1 abgelehnt; fremder Namespace immer RBAC | `admission-abgelehnt` bzw. `rbac-verweigert` |
| `make scenario AK=14` | signiertes Image, aber unsichere Pod-Konfiguration (privilegiert, root, Host-Netz) | ab V3 abgelehnt (Pod-Sicherheitsrichtlinie) | `admission-abgelehnt` mit eigener Meldung je Fall |

### GitHub-Szenarien

Diese greifen echt über GitHub an (Branches, Pull Requests, Workflow-Starts) und brauchen daher einen eigenen Fork mit aktivierten Actions. Weil ein Push auf `main` alle vier Varianten gleichzeitig baut, der lokale Cluster aber nur eine Variante trägt, greift der **erste** Aufruf einmal echt an, hält das Ergebnis je Variante fest und stellt die Repositories sofort wieder her; jeder weitere Aufruf (andere Variante) wertet nur noch aus. Ein erneuter Angriff wird mit `ANGRIFF=neu` erzwungen.

Einige dieser Szenarien bringen den Angriff über einen **signierten Commit** auf `main` ein. Das Skript bereitet die Änderung vor und nennt den genauen `git commit`-Befehl, den du ausführst (gitsign öffnet dazu einen Browser-Login); danach rufst du dasselbe `make scenario` erneut auf. Zum Schluss nimmt ein ebenfalls signierter Revert die Änderung wieder zurück.

| Befehl | Angriff | Erwartet |
|---|---|---|
| `make scenario AK=05` | Build von einem inoffiziellen Feature-Branch; eigene Build-Schritte auf `main` | Feature-Branch ab V1, eigene Build-Schritte ab V2 abgewehrt |
| `make scenario AK=06` | zusätzlicher Job signiert ein manipuliertes Image | ab V2 abgewehrt (V3 schon in der Pipeline durch zizmor) |
| `make scenario AK=10a` | Dependency Confusion: `firma-utils 99.0.0` in die öffentliche Paketquelle | bis V2 durchgelassen (Seite zeigt 99.0.0), ab V3 bleibt es bei 1.0.0 |
| `make scenario AK=11` | verwundbare Abhängigkeit (Werkzeug 0.15.2) hinzugefügt | bis V2 durchgelassen, ab V3 am Schwachstellen-Gate abgelehnt |
| `make scenario AK=02-03` | Commit mit gefälschtem Autor (und Variante: Prüfung im App-Workflow entfernt) | gefälschter Autor ab V1, mit entfernter Prüfung erst ab V2 abgewehrt |

> **Achtung AK-02-03:** Dieses Szenario bringt gefälschte Commits dauerhaft in die Historie; danach bauen V1–V3 erst wieder, wenn der Vertrauensanker vorgeschoben ist. Das Skript macht das automatisch (ein signierter Commit von dir, zwei Pull Requests) und prüft am Ende, dass alles wieder grün baut. Nur mit funktionierendem Fork ausführen.

## Auf dem eigenen GitHub-Account ausprobieren (Forks)

> Die ausführliche Anleitung folgt. Schon jetzt fest steht, was nach dem Forken der drei Repositories nötig ist:

- In jedem Fork unter „Actions“ die Workflows aktivieren (in Forks sind sie zunächst ausgeschaltet).
- Eine eigene GitHub-App für Renovate anlegen und installieren, siehe [Eigene Renovate-App einrichten](#eigene-renovate-app-einrichten). Renovate hält die gepinnten Abhängigkeiten von Variante V3 aktuell.
- Account-Namen und E-Mail-Adresse in den Forks anpassen (dafür wird es einen eigenen Befehl geben).
- Den Branch `main` in den Forks von `example-app` und `secure-workflows` schützen, siehe [main schützen](#main-schützen).

### main schützen

**Worum es geht:** Die Prüfungen der Pipeline verlassen sich darauf, dass Änderungen nur über Pull Requests auf `main` kommen und die Historie nicht umgeschrieben wird. Das stellt GitHub mit einem Ruleset sicher. Es gilt für den Branch `main` von `example-app` und `secure-workflows`:

| Regel | Warum |
|---|---|
| Änderungen nur über Pull Requests, 0 Freigaben nötig | Kein direkter Push auf `main`. Freigaben durch eine zweite Person sind mit nur einem Account nicht möglich. |
| Zusammenführen nur als Merge-Commit | Squash und Rebase würden die Commits ersetzen und deren Signaturen verlieren. |
| Kein Force-Push, kein Löschen von `main` | Die Historie bleibt unverändert, die Commit-Prüfung bleibt gültig. |
| Keine Ausnahmen, auch nicht für Admins | Sonst wäre der Schutz mit einem übernommenen Admin-Account wirkungslos. |

Die Regeln stehen in `config/github/ruleset-main.json`. Anwenden mit:

```sh
make protect-repos
```

Der Befehl braucht die [GitHub CLI](https://cli.github.com/) (`gh`), angemeldet mit deinem Account. Er kann beliebig oft ausgeführt werden und aktualisiert dann die vorhandenen Regeln. Prüfen lässt sich das Ergebnis mit:

```sh
gh api repos/<dein-account>/example-app/rules/branches/main --jq '.[].type'
# deletion, non_fast_forward, pull_request
```

### Eigene Renovate-App einrichten

**Worum es geht:** Renovate ist ein Bot, der Abhängigkeiten aktuell hält und dafür Pull Requests öffnet. Ab Variante V1 akzeptiert die Pipeline nur signierte Commits. Damit auch die Commits des Bots prüfbar signiert sind, läuft Renovate nicht als fertige App eines Anbieters, sondern als Workflow in deinem Fork von `secure-workflows`. Dort signiert er mit der Identität dieses Workflows. Um auf deine Repositories zuzugreifen, braucht der Workflow eine eigene GitHub-App. Sie gehört dir und darf nur, was Renovate braucht.

Du brauchst dafür die [GitHub CLI](https://cli.github.com/) (`gh`), angemeldet mit deinem Account (`gh auth login`). An drei Stellen ist ein Klick im Browser nötig (App bestätigen, Schlüssel erzeugen, App installieren), das lässt GitHub nicht anders zu.

**1. App anlegen.** Der Befehl öffnet GitHub mit einer vorausgefüllten App: Name, kein Webhook, nur die Rechte, die Renovate braucht. Klicke dort unten auf **Create GitHub App**.

```sh
OWNER=dein-account   # dein GitHub-Account Name
APP=$OWNER-testbed-renovate

open "https://github.com/settings/apps/new?name=$APP&url=https://github.com/$OWNER/secure-workflows&public=false&webhook_active=false&administration=read&checks=write&contents=write&issues=write&metadata=read&pull_requests=write&statuses=write&vulnerability_alerts=read&workflows=write"
```

Unter Linux `xdg-open` statt `open`.

**2. Privaten Schlüssel herunterladen.** Auf der Seite der neuen App unter „Private keys“ auf **Generate a private key** klicken. Der Browser lädt eine Datei `<app>.<datum>.private-key.pem` herunter.

**3. App-ID und Schlüssel in `secure-workflows` hinterlegen.** Der Renovate-Workflow holt sich damit bei jedem Lauf ein Zugangstoken, das nach einer Stunde abläuft.

```sh
# Copy the App ID from the following link
open https://github.com/settings/apps/$APP
```

```sh
# Enter the App ID from the step before
APP_ID="ENTER_APP_ID_HERE"

gh variable set RENOVATE_APP_ID --repo "$OWNER/secure-workflows" --body "$APP_ID"
gh secret set RENOVATE_APP_PRIVATE_KEY --repo "$OWNER/secure-workflows" < ~/Downloads/$APP.*.private-key.pem

# Der Schlüssel liegt jetzt als Secret bei GitHub, die Datei wird nicht mehr gebraucht.
rm ~/Downloads/$APP.*.private-key.pem
```

**4. App installieren.** Der Befehl öffnet die Installationsseite. Dort **Only select repositories** wählen, `example-app` und `secure-workflows` auswählen und auf **Install** klicken.

```sh
open "https://github.com/apps/$APP/installations/new"
```

**5. Prüfen.**

```sh
gh variable list --repo "$OWNER/secure-workflows"   # zeigt RENOVATE_APP_ID
gh secret list --repo "$OWNER/secure-workflows"     # zeigt RENOVATE_APP_PRIVATE_KEY
```
