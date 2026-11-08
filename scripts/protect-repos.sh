#!/usr/bin/env bash
# Schuetzt den Branch main in example-app und secure-workflows:
# Aenderungen nur ueber Pull Requests, nur Merge-Commits, kein Force-Push,
# kein Loeschen, keine Ausnahmen fuer Admins (config/github/ruleset-main.json).
# Mehrfach ausfuehrbar: Ein vorhandenes Ruleset gleichen Namens wird aktualisiert.
source "$(dirname "$0")/lib.sh"

RULESET_FILE="$TESTBED_DIR/config/github/ruleset-main.json"
RULESET_NAME="$(jq -r .name "$RULESET_FILE")"

protect_repo() {
  local repo="$GITHUB_OWNER/$1"
  step "$repo: main schuetzen"

  # Squash und Rebase ersetzen die Commits und damit deren gitsign-Signaturen.
  gh repo edit "$repo" --enable-merge-commit=true --enable-squash-merge=false \
    --enable-rebase-merge=false --delete-branch-on-merge=true >/dev/null
  info "Nur Merge-Commits erlaubt."

  local ruleset_id
  ruleset_id="$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id")"
  if [ -n "$ruleset_id" ]; then
    gh api --method PUT "repos/$repo/rulesets/$ruleset_id" --input "$RULESET_FILE" >/dev/null
    info "Ruleset '$RULESET_NAME' aktualisiert."
  else
    gh api --method POST "repos/$repo/rulesets" --input "$RULESET_FILE" >/dev/null
    info "Ruleset '$RULESET_NAME' angelegt."
  fi
}

protect_repo example-app
protect_repo secure-workflows

step "Fertig: main ist in beiden Repositories geschuetzt"
