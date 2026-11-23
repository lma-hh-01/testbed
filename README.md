# testbed

Testbed zur Absicherung der Software Supply Chain in Kubernetes. Es setzt die Toolchain in vier aufeinander aufbauenden Varianten um und prüft mit Angriffsszenarien, ab welcher Variante eine Angriffsklasse abgewehrt wird.

## Überblick

Drei Repositories arbeiten zusammen:

| Repository | Inhalt |
|---|---|
| `testbed` (dieses) | kind-Cluster, lokale Registry (zot), Kyverno, Skripte, Szenarien, Makefile |
| `example-app` | Beispielanwendung mit Dockerfile, Kubernetes-Manifesten und den Aufrufer-Workflows `v0`–`v3` |
| `secure-workflows` | zentrale wiederverwendbare Workflows und die Kyverno-Richtlinien je Variante |

Die vier Varianten:

| Variante | Härtung |
|---|---|
| **V0** | Basislinie ohne Härtung (keine Signatur, keine Prüfung an der Admission) |
| **V1** | Signatur (Cosign) + Digest-Pflicht + Commit-Signaturen (gitsign), Prüfung an der Admission |
| **V2** | zusätzlich Provenance über einen zentralen Workflow, Prüfung von Builder-Identität und Quelle |
| **V3** | zusätzlich SBOM, Schwachstellen-Gate, Pinning, Workflow- und Manifest-Prüfung, Pod-Sicherheit |

## Voraussetzungen

Benötigt werden Docker (laufend) sowie `kind`, `kubectl`, `helm`, `oras`, `cosign`, die Kyverno CLI, `jq`, `yq`, `git`, `curl` und die GitHub CLI `gh`. Die genauen Versionen stehen in `versions.env`. Ob alles vorhanden ist, prüft:

```sh
make check-tools
```

Auf Apple Silicon muss in Docker Desktop „Use Rosetta for x86_64/amd64 emulation“ aktiv sein (die Images sind amd64). `make check-tools` weist darauf sowie unter Linux auf die empfohlenen inotify-Grenzen hin.

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
make check-tools          # check the tools
make cluster VARIANT=v0   # set up the local environment
make deploy               # deploy the application, then open http://localhost:8080
make down                 # tear everything down again
```

## Angriffsszenarien

Jedes Szenario spielt einen Angriff aus dem Bedrohungsmodell gegen die gerade laufende Variante durch und hält das Ergebnis fest. So wird sichtbar, ab welcher Variante ein Angriff abgewehrt wird.

```sh
make cluster VARIANT=v1     # set up the variant to test against
make scenario AK=13         # run the scenario
```

Das Ergebnis jedes Szenarios ist eines von:

- **allowed** – der Angriff war erfolgreich, das Image läuft im Cluster,
- **admission-denied** – die Prüfung an der Admission hat das Deployment abgelehnt,
- **build-aborted** – schon die Pipeline hat den Angriff gestoppt, es entstand kein Image,
- **rbac-denied** – die Rechtevergabe im Cluster hat die Aktion verhindert,
- **correct-version** – nur bei AK-10a: trotz Angriff wurde die richtige Paketversion eingebaut.

Jedes Ergebnis wird ausgegeben und in `.work/scenario-results.csv` geschrieben (anderer Ort mit `make scenario AK=.. RESULTS=results/scenario-results.csv`). Jede Zeile nennt Variante, Angriffsklasse, Fall und Ergebnis. Die Ergebnisse des Messlaufs vom 22.11.2026 stehen in `results/scenario-results.csv`, die Spalte „Ergebnis im Messlauf“ in den Tabellen unten fasst sie zusammen.

### Lokale Szenarien

Diese laufen vollständig auf dem Rechner, ohne GitHub. Ein frisch gebautes oder verändertes Image wird direkt in die lokale Registry gelegt und als eingeschränkter Deployer deployt.

| Befehl | Angriff | Ergebnis im Messlauf | Woran erkennbar |
|---|---|---|---|
| `make scenario AK=07` | Image außerhalb der Pipeline gebaut und direkt in die Registry gelegt | ab V1 abgelehnt (Signatur der Pipeline fehlt) | Ergebnis `admission-denied`, Meldung „is not signed“ |
| `make scenario AK=08` | signiertes Image verändert, Original-Signatur umgehängt | ab V1 abgelehnt (Signatur deckt den neuen Digest nicht) | `admission-denied`, Digest-Bindung |
| `make scenario AK=09` | Tag in der Registry auf ein untergeschobenes Image umgehängt | ab V1 abgelehnt (Digest-Pflicht) | `admission-denied`, „does not have a digest“ |
| `make scenario AK=10b` | fremdes Image unter vertipptem Namen (`ngnix`) | ab V1 abgelehnt (Signatur fehlt) | `admission-denied` |
| `make scenario AK=12` | Deployer versucht, die Verifikation zu ändern (Richtlinie, Webhook, Rechte) | in allen Varianten verweigert (RBAC) | `rbac-denied` je Teil-Angriff |
| `make scenario AK=13` | unsigniertes Image per Pod/Deployment/Job/CronJob und in fremdem Namespace | ab V1 abgelehnt; fremder Namespace immer RBAC | `admission-denied` bzw. `rbac-denied` |
| `make scenario AK=14` | signiertes Image, aber unsichere Pod-Konfiguration (privilegiert, root, Host-Netz) | ab V3 abgelehnt (Pod-Sicherheitsrichtlinie) | `admission-denied` mit eigener Meldung je Fall |

### GitHub-Szenarien

Diese greifen echt über GitHub an (Branches, Pull Requests, Workflow-Starts) und brauchen daher einen eigenen Fork mit aktivierten Actions. Weil ein Push auf `main` alle vier Varianten gleichzeitig baut, der lokale Cluster aber nur eine Variante trägt, greift der **erste** Aufruf einmal echt an, hält das Ergebnis je Variante fest und stellt die Repositories sofort wieder her; jeder weitere Aufruf (andere Variante) wertet nur noch aus. Ein erneuter Angriff wird mit `ATTACK=new` erzwungen.

Einige dieser Szenarien bringen den Angriff über einen **signierten Commit** auf `main` ein. Das Skript bereitet die Änderung vor und nennt den genauen `git commit`-Befehl, den du ausführst (gitsign öffnet dazu einen Browser-Login); danach rufst du dasselbe `make scenario` erneut auf. Zum Schluss nimmt ein ebenfalls signierter Revert die Änderung wieder zurück.

| Befehl | Angriff | Ergebnis im Messlauf |
|---|---|---|
| `make scenario AK=05` | Build von einem inoffiziellen Feature-Branch; eigene Build-Schritte auf `main` | Feature-Branch ab V1, eigene Build-Schritte ab V2 abgewehrt |
| `make scenario AK=06` | zusätzlicher Job signiert ein manipuliertes Image | ab V2 abgewehrt (V3 schon in der Pipeline durch zizmor) |
| `make scenario AK=10a` | Dependency Confusion: `company-utils 99.0.0` in die öffentliche Paketquelle | bis V2 durchgelassen (Seite zeigt 99.0.0), ab V3 bleibt es bei 1.0.0 |
| `make scenario AK=11` | verwundbare Abhängigkeit (Werkzeug 0.15.2) hinzugefügt | bis V2 durchgelassen; in V3 stoppt das Schwachstellen-Gate die Signatur, das unsignierte Image wird an der Admission abgelehnt |
| `make scenario AK=02-03` | Commit mit gefälschtem Autor (und Variante: Prüfung im App-Workflow entfernt) | gefälschter Autor ab V1, mit entfernter Prüfung erst ab V2 abgewehrt |

> **Achtung AK-02-03:** Dieses Szenario bringt gefälschte Commits dauerhaft in die Historie; danach bauen V1–V3 erst wieder, wenn der Vertrauensanker vorgeschoben ist. Das Skript macht das automatisch (ein signierter Commit von dir, zwei Pull Requests) und prüft am Ende, dass alles wieder grün baut. Nur mit funktionierendem Fork ausführen.

## Auf dem eigenen GitHub-Account ausprobieren (Forks)

Die lokalen Szenarien laufen mit den veröffentlichten Images von `lma-hh-01`. Für die GitHub-Szenarien (echte Angriffe über Pipeline-Läufe) brauchst du eigene Forks der drei Repositories. Der Ablauf einmalig:

1. Die drei Repositories auf den eigenen Account **forken** (`testbed`, `example-app`, `secure-workflows`) und nebeneinander klonen.
2. In jedem Fork unter **Actions** die Workflows aktivieren (in Forks sind sie zunächst ausgeschaltet).
3. Account-Namen und gitsign-E-Mail in den Klonen anpassen, siehe [Namen anpassen](#namen-anpassen).
4. Die angepassten Dateien committen und als Pull Request nach `main` bringen: `example-app` **signiert** (gitsign), `secure-workflows` normal; in `testbed` reicht ein direkter Commit.
5. Den Branch `main` in `example-app` und `secure-workflows` schützen, siehe [main schützen](#main-schützen).
6. Optional: eine eigene Renovate-App einrichten, siehe [Eigene Renovate-App einrichten](#eigene-renovate-app-einrichten). Renovate hält die gepinnten Abhängigkeiten von Variante V3 aktuell.

### Namen anpassen

Der Account-Name `lma-hh-01` und die gitsign-E-Mail stehen an wenigen festen Stellen in den Workflows, Kyverno-Richtlinien und Skripten (alle übrigen Stellen passen sich über `${{ github.repository_owner }}` von selbst an). Ein Befehl ersetzt sie in den drei Klonen:

```sh
make fork-setup OWNER=your-account EMAIL=your-gitsign-mail@example.org
```

`OWNER` ist dein GitHub-Account, `EMAIL` die Adresse, mit der du Commits per gitsign signierst (deine bei GitHub hinterlegte Adresse). Der Befehl ändert nur Dateien; committen, pushen und die Repo-Einstellungen bleiben bewusst manuell, weil ein Commit auf `example-app` signiert sein muss. Dieser erste signierte Commit trägt zugleich deine E-Mail in die Signierer-Liste (`ALLOWED_SIGNERS`) ein und besteht damit die eigene Commit-Prüfung.

Wenn du Renovate nutzt: Die numerische Benutzer-ID deiner Renovate-App ist erst nach deren Anlage bekannt und muss danach in `ALLOWED_SIGNERS` (in `example-app/.github/workflows/v1.yml` sowie `secure-workflows/.github/workflows/v2.yml` und `v3.yml`) eingetragen werden:

```sh
gh api "/users/your-account-testbed-renovate[bot]" --jq .id
```

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
gh api repos/<your-account>/example-app/rules/branches/main --jq '.[].type'
# deletion, non_fast_forward, pull_request
```

### Eigene Renovate-App einrichten

**Worum es geht:** Renovate ist ein Bot, der Abhängigkeiten aktuell hält und dafür Pull Requests öffnet. Ab Variante V1 akzeptiert die Pipeline nur signierte Commits. Damit auch die Commits des Bots prüfbar signiert sind, läuft Renovate nicht als fertige App eines Anbieters, sondern als Workflow in deinem Fork von `secure-workflows`. Dort signiert er mit der Identität dieses Workflows. Um auf deine Repositories zuzugreifen, braucht der Workflow eine eigene GitHub-App. Sie gehört dir und darf nur, was Renovate braucht.

Du brauchst dafür die [GitHub CLI](https://cli.github.com/) (`gh`), angemeldet mit deinem Account (`gh auth login`). An drei Stellen ist ein Klick im Browser nötig (App bestätigen, Schlüssel erzeugen, App installieren), das lässt GitHub nicht anders zu.

**1. App anlegen.** Der Befehl öffnet GitHub mit einer vorausgefüllten App: Name, kein Webhook, nur die Rechte, die Renovate braucht. Klicke dort unten auf **Create GitHub App**.

```sh
OWNER=your-account   # your GitHub account name
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

# The key is now stored as a secret on GitHub, the file is no longer needed.
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
