#!/usr/bin/env bash
# Protects the branch main in example-app and secure-workflows:
# changes only via pull requests, only merge commits, no force push,
# no deletion, no exceptions for admins (config/github/ruleset-main.json).
# Can be run repeatedly: an existing ruleset with the same name is updated.
source "$(dirname "$0")/lib.sh"

RULESET_FILE="$TESTBED_DIR/config/github/ruleset-main.json"
RULESET_NAME="$(jq -r .name "$RULESET_FILE")"

protect_repo() {
  local repo="$GITHUB_OWNER/$1"
  step "$repo: protect main"

  # Squash and rebase replace the commits and with them their gitsign signatures.
  gh repo edit "$repo" --enable-merge-commit=true --enable-squash-merge=false \
    --enable-rebase-merge=false --delete-branch-on-merge=true >/dev/null
  info "Only merge commits allowed."

  local ruleset_id
  ruleset_id="$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id")"
  if [ -n "$ruleset_id" ]; then
    gh api --method PUT "repos/$repo/rulesets/$ruleset_id" --input "$RULESET_FILE" >/dev/null
    info "Ruleset '$RULESET_NAME' updated."
  else
    gh api --method POST "repos/$repo/rulesets" --input "$RULESET_FILE" >/dev/null
    info "Ruleset '$RULESET_NAME' created."
  fi
}

protect_repo example-app
protect_repo secure-workflows

step "Done: main is protected in both repositories"
