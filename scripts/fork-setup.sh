#!/usr/bin/env bash
# Passt die drei lokalen Klone an einen eigenen GitHub-Account an: ersetzt den
# Account-Namen und die gitsign-E-Mail an den wenigen literalen Stellen. Die
# uebrigen Stellen nutzen ${{ github.repository_owner }} und passen sich von
# selbst an.
#
# Committen, Pushen und die Repo-Einstellungen bleiben bewusst manuell: Ein
# Commit auf example-app muss ab dem Vertrauensanker signiert sein (gitsign,
# Browser-Login), das kann ein Skript nicht uebernehmen. Die naechsten Schritte
# stehen am Ende der Ausgabe und in der README (Abschnitt "Forks").
#
# Aufruf: make fork-setup OWNER=<github-account> EMAIL=<gitsign-mail>
source "$(dirname "$0")/lib.sh"

OWNER="${OWNER:-}"
EMAIL="${EMAIL:-}"
[ -n "$OWNER" ] && [ -n "$EMAIL" ] ||
  fail "Aufruf: make fork-setup OWNER=<github-account> EMAIL=<gitsign-mail>"

OLD_OWNER="lma-hh-01"
OLD_EMAIL="lma-hh-01@mailbox.org"
REPO_ROOT="$(dirname "$TESTBED_DIR")"

if [ "$OWNER" = "$OLD_OWNER" ]; then
  fail "OWNER ist bereits '$OLD_OWNER'. Nichts zu tun."
fi

# Ersetzt in einer Datei erst die volle E-Mail, dann den Account-Namen. Die
# Reihenfolge ist wichtig, weil OLD_EMAIL den OLD_OWNER enthaelt.
rewrite() {
  local file="$1"
  [ -f "$file" ] || fail "Erwartete Datei fehlt: $file"
  sed -e "s|$OLD_EMAIL|$EMAIL|g" -e "s|$OLD_OWNER|$OWNER|g" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
  info "angepasst: ${file#"$REPO_ROOT"/}"
}

step "Account '$OLD_OWNER' -> '$OWNER', E-Mail '$OLD_EMAIL' -> '$EMAIL'"

# example-app: Aufrufer-Workflows (uses:, ALLOWED_SIGNERS) und Renovate-Regel.
rewrite "$EXAMPLE_APP_DIR/.github/workflows/v1.yml"
rewrite "$EXAMPLE_APP_DIR/.github/workflows/v2.yml"
rewrite "$EXAMPLE_APP_DIR/.github/workflows/v3.yml"
rewrite "$EXAMPLE_APP_DIR/.github/workflows/v3-rescan.yml"
rewrite "$EXAMPLE_APP_DIR/renovate.json"

# secure-workflows: zentrale Workflows (ALLOWED_SIGNERS), Richtlinien, zizmor, CODEOWNERS.
rewrite "$SECURE_WORKFLOWS_DIR/.github/workflows/v2.yml"
rewrite "$SECURE_WORKFLOWS_DIR/.github/workflows/v3.yml"
rewrite "$SECURE_WORKFLOWS_DIR/policies/v1/require-signed-images.yaml"
rewrite "$SECURE_WORKFLOWS_DIR/policies/v2/require-provenance.yaml"
rewrite "$SECURE_WORKFLOWS_DIR/policies/v3/require-provenance-and-sbom.yaml"
rewrite "$SECURE_WORKFLOWS_DIR/zizmor.yml"
rewrite "$SECURE_WORKFLOWS_DIR/.github/CODEOWNERS"

# testbed: GITHUB_OWNER fuer die Skripte.
rewrite "$TESTBED_DIR/scripts/lib.sh"

step "Noch von Hand (siehe README, Abschnitt \"Auf dem eigenen GitHub-Account\")"
info "1. Renovate nutzt du? Dann in ALLOWED_SIGNERS (v1/v2/v3) die numerische"
info "   Bot-User-ID der EIGENEN Renovate-App eintragen (erst nach deren Anlage"
info "   bekannt): gh api '/users/${OWNER}-testbed-renovate[bot]' --jq .id"
info "2. example-app signiert committen (gitsign), secure-workflows und testbed"
info "   normal; je als Pull Request mergen (bzw. testbed direkt)."
info "3. make protect-repos  (Ruleset auf main in example-app und secure-workflows)."
