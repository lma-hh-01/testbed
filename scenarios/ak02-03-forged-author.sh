#!/usr/bin/env bash
# AK-02/03: Commit with a forged author.
# Two cases, both as a real attack on example-app/main:
#   forged-author (hyp V1): a commit with a forged author and without a valid
#     signature is merged. The commit verification in the workflow stops the
#     build, no image is produced -> defended from V1 on.
#   check-removed (hyp V2): in the same go the attacker removes the commit
#     verification from the app workflow (only possible in V1). V1 then builds
#     and signs anyway -> not defended. V2/V3 keep verifying in the central
#     workflow -> defended from V2 on.
#
# WARNING: This scenario changes the basis of trust permanently. The forged
# commits stay in the history, V1-V3 fail afterwards until the trust anchor has
# been moved forward. The restore moves the anchor in secure-workflows (v2/v3,
# normal PR) and in example-app (v1, signed commit by Lukas) to the attack merge
# and resets the code to the state before the attack. Only run it with the
# anchor restore ready. The attack itself is unsigned and created without Lukas;
# only the restore needs a signature.
source "$(dirname "$0")/lib.sh"

AK="AK-02/03"
# shellcheck disable=SC2034 # AK_FLAG is read by the driver/print_sign_prompt in lib.sh
AK_FLAG="02-03"
FORGED_AUTHOR="AK0203 Forger <forger@attacker.invalid>"
ANCHOR_BRANCH_APP="ak0203-anchor-example-app"
RESTORE_TITLE="AK-02/03 restore: reset code and move trust anchor"

describe "$AK" "Commit with a forged author" \
  "A commit with a forged author is merged into main (forged-author), in the second case additionally with the commit verification removed from the app workflow (check-removed). Expected: forged-author defended from V1 on (the build stops), check-removed only from V2 on (the verification then lives in the central workflow)."

github_scenario_guard

# --- Attacks -----------------------------------------------------------------

# Modifies app/main.py so that the forged commit carries a change.
forge_harmless_change() {
  printf '\n# AK-02/03: change by an unauthorized author\n' \
    >> "$EXAMPLE_APP_DIR/app/main.py"
}

# Additionally removes the commit verification from the app workflow v1.yml.
forge_and_remove_check() {
  forge_harmless_change
  local wf="$EXAMPLE_APP_DIR/.github/workflows/v1.yml"
  yq 'del(.jobs.build.steps[] | select(.name == "Verify commit signatures"))' "$wf" > "$wf.tmp"
  mv "$wf.tmp" "$wf"
}

# Creates a branch with a forged, unsigned commit and merges it into main via a
# PR. Sets MERGE_COMMIT.
forged_merge() {
  local branch="$1" title="$2" modify_fn="$3"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  git -C "$EXAMPLE_APP_DIR" switch --quiet -C "$branch" origin/main
  "$modify_fn"
  git -C "$EXAMPLE_APP_DIR" add -A
  git -C "$EXAMPLE_APP_DIR" -c commit.gpgsign=false commit --quiet \
    --author="$FORGED_AUTHOR" -m "$title"
  open_and_merge_pr "$EXAMPLE_APP_REPO" "$branch" "$title" "$EXAMPLE_APP_DIR"
}

# --- Restore (move the anchor) -----------------------------------------------

# Sets the trust anchor in a workflow file to the given commit.
set_anchor() {
  local file="$1" anchor="$2"
  sed "s/\(TRUST_ANCHOR: \).*/\1$anchor/" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# Moves the anchor in secure-workflows (v2, v3) via a normal PR (no signature).
move_platform_anchor() {
  local anchor="$1" branch="ak0203-anchor-platform" f
  git -C "$SECURE_WORKFLOWS_DIR" fetch --quiet origin main
  git -C "$SECURE_WORKFLOWS_DIR" switch --quiet -C "$branch" origin/main
  for f in v2 v3; do
    set_anchor "$SECURE_WORKFLOWS_DIR/.github/workflows/$f.yml" "$anchor"
  done
  git -C "$SECURE_WORKFLOWS_DIR" add -A
  git -C "$SECURE_WORKFLOWS_DIR" -c commit.gpgsign=false commit --quiet \
    -m "AK-02/03 restore: move trust anchor"
  open_and_merge_pr "$SECURE_WORKFLOWS_REPO" "$branch" \
    "AK-02/03 restore: move trust anchor" "$SECURE_WORKFLOWS_DIR"
}

# Prepares the anchor commit in example-app: resets all files to the state
# before the attack (undoes the forged changes) and sets the anchor in v1.yml to
# the attack merge. Lukas commits it signed.
prepare_app_anchor() {
  local base="$1" anchor="$2"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  git -C "$EXAMPLE_APP_DIR" switch --quiet -C "$ANCHOR_BRANCH_APP" origin/main
  git -C "$EXAMPLE_APP_DIR" checkout "$base" -- .
  set_anchor "$EXAMPLE_APP_DIR/.github/workflows/v1.yml" "$anchor"
  git -C "$EXAMPLE_APP_DIR" add -A
}

# --- Procedure ---------------------------------------------------------------

STATE="ak0203"
PHASE_FILE="$STATE_DIR/$STATE.phase"
mkdir -p "$STATE_DIR"
PHASE=fresh
# shellcheck source=/dev/null
[ -f "$PHASE_FILE" ] && source "$PHASE_FILE"
[ "${ATTACK:-}" = new ] && PHASE=fresh

if [ "$PHASE" = fresh ]; then
  step "Record the state before the attack"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  BASE="$(git -C "$EXAMPLE_APP_DIR" rev-parse origin/main)"
  info "Base: ${BASE:0:7}"

  step "Case forged-author: commit with a forged author to main"
  forged_merge ak0203-forged-author \
    "AK-02/03: commit with a forged author" forge_harmless_change
  record_push_builds "${STATE}-forged-author" "$MERGE_COMMIT"

  step "Case check-removed: forged author and commit verification removed from v1.yml"
  forged_merge ak0203-check-removed \
    "AK-02/03: commit verification removed from the app workflow" forge_and_remove_check
  record_push_builds "${STATE}-check-removed" "$MERGE_COMMIT"
  ANCHOR="$MERGE_COMMIT"

  step "Restore 1/2: move the trust anchor in secure-workflows"
  move_platform_anchor "$ANCHOR"

  step "Prepare restore 2/2: anchor in example-app/v1.yml"
  prepare_app_anchor "$BASE" "$ANCHOR"
  printf 'PHASE=restore-prepared\n' > "$PHASE_FILE"
  print_sign_prompt "$ANCHOR_BRANCH_APP" "$RESTORE_TITLE" "$AK_FLAG"
  exit 0
fi

if [ "$PHASE" = restore-prepared ]; then
  if ! has_signed_commit "$ANCHOR_BRANCH_APP"; then
    print_sign_prompt "$ANCHOR_BRANCH_APP" "$RESTORE_TITLE" "$AK_FLAG"
    exit 0
  fi
  step "Restore 2/2: anchor commit in example-app to main"
  open_and_merge_pr "$EXAMPLE_APP_REPO" "$ANCHOR_BRANCH_APP" \
    "AK-02/03 restore: move trust anchor" "$EXAMPLE_APP_DIR"
  verify_restore_green "$MERGE_COMMIT"
  printf 'PHASE=done\n' > "$PHASE_FILE"
fi

# PHASE=done: evaluate both cases against the running variant.
evaluate_from_state "$AK" forged-author V1 "${STATE}-forged-author"
evaluate_from_state "$AK" check-removed V2 "${STATE}-check-removed"
