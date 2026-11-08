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
