#!/usr/bin/env bash
# Adapts the three local clones to your own GitHub account: replaces the
# account name and the gitsign email at the few literal places. All other
# places use ${{ github.repository_owner }} and adapt by themselves.
#
# Committing, pushing and the repository settings deliberately stay manual: from
# the trust anchor on, a commit to example-app must be signed (gitsign, browser
# login), which a script cannot do. The next steps are printed at the end of the
# output and described in the README (section "Forks").
#
# Usage: make fork-setup OWNER=<github-account> EMAIL=<gitsign-mail>
source "$(dirname "$0")/lib.sh"

OWNER="${OWNER:-}"
EMAIL="${EMAIL:-}"
[ -n "$OWNER" ] && [ -n "$EMAIL" ] ||
  fail "Usage: make fork-setup OWNER=<github-account> EMAIL=<gitsign-mail>"

OLD_OWNER="lma-hh-01"
OLD_EMAIL="lma-hh-01@mailbox.org"
REPO_ROOT="$(dirname "$TESTBED_DIR")"

if [ "$OWNER" = "$OLD_OWNER" ]; then
  fail "OWNER is already '$OLD_OWNER'. Nothing to do."
fi

# Replaces the full email first and then the account name in a file. The order
# matters because OLD_EMAIL contains OLD_OWNER.
rewrite() {
  local file="$1"
  [ -f "$file" ] || fail "Expected file is missing: $file"
  sed -e "s|$OLD_EMAIL|$EMAIL|g" -e "s|$OLD_OWNER|$OWNER|g" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
  info "adapted: ${file#"$REPO_ROOT"/}"
}

step "Account '$OLD_OWNER' -> '$OWNER', email '$OLD_EMAIL' -> '$EMAIL'"

# example-app: caller workflows (uses:, ALLOWED_SIGNERS) and Renovate rule.
rewrite "$EXAMPLE_APP_DIR/.github/workflows/v1.yml"
rewrite "$EXAMPLE_APP_DIR/.github/workflows/v2.yml"
rewrite "$EXAMPLE_APP_DIR/.github/workflows/v3.yml"
rewrite "$EXAMPLE_APP_DIR/.github/workflows/v3-rescan.yml"
rewrite "$EXAMPLE_APP_DIR/renovate.json"

# secure-workflows: central workflows (ALLOWED_SIGNERS), policies, zizmor, CODEOWNERS.
rewrite "$SECURE_WORKFLOWS_DIR/.github/workflows/v2.yml"
rewrite "$SECURE_WORKFLOWS_DIR/.github/workflows/v3.yml"
rewrite "$SECURE_WORKFLOWS_DIR/policies/v1/require-signed-images.yaml"
rewrite "$SECURE_WORKFLOWS_DIR/policies/v2/require-provenance.yaml"
rewrite "$SECURE_WORKFLOWS_DIR/policies/v3/require-provenance-and-sbom.yaml"
rewrite "$SECURE_WORKFLOWS_DIR/zizmor.yml"
rewrite "$SECURE_WORKFLOWS_DIR/.github/CODEOWNERS"

# testbed: GITHUB_OWNER for the scripts.
rewrite "$TESTBED_DIR/scripts/lib.sh"

step "Still to do by hand (see README, section \"Auf dem eigenen GitHub-Account ausprobieren (Forks)\")"
info "1. Using Renovate? Then enter the numeric bot user ID of your OWN"
info "   Renovate app in ALLOWED_SIGNERS (v1/v2/v3) (only known after the"
info "   app has been created): gh api '/users/${OWNER}-testbed-renovate[bot]' --jq .id"
info "2. Commit example-app signed (gitsign), secure-workflows and testbed"
info "   normally; merge each as a pull request (testbed directly)."
info "3. make protect-repos  (ruleset on main in example-app and secure-workflows)."
