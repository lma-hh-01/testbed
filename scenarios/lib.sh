#!/usr/bin/env bash
# Shared helper functions for the attack scenarios.
# The scenario scripts include this file with "source".
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

[ -f "$WORK_DIR/variant" ] || fail "No testbed found. Run 'make cluster VARIANT=...' first."
VARIANT="$(cat "$WORK_DIR/variant")"

SCENARIO_DIR="$WORK_DIR/scenarios"
mkdir -p "$SCENARIO_DIR"
RESULTS_FILE="${RESULTS_FILE:-$WORK_DIR/scenario-results.csv}"
mkdir -p "$(dirname "$RESULTS_FILE")"
RESULTS_HEADER="timestamp,variant,attack_class,case,result,detail,artifact,repo_state"

# --- Output -------------------------------------------------------------------

describe() {
  local ak="$1"
  local title="$2"
  local text="$3"
  printf '\n### %s: %s (variant %s)\n' "$ak" "$title" "$VARIANT"
  printf '%s\n' "$text" | fold -s -w 76 | sed 's/^/    /'
}

# --- Manifests ----------------------------------------------------------------

# Creates a manifest for a Pod, Deployment, Job or CronJob. The containers
# satisfy the pod security policy of V3, so that a denial can only be caused by
# the examined property and not by the security configuration.
workload_manifest() {
  local kind="$1"
  local name="$2"
  local image="$3"
  local namespace="${4:-$APP_NAMESPACE}"
  local create
  case "$kind" in
    pod) create=(run "$name" --image "$image" --restart Never) ;;
    deployment) create=(create deployment "$name" --image "$image") ;;
    job) create=(create job "$name" --image "$image") ;;
    cronjob) create=(create cronjob "$name" --image "$image" --schedule '*/30 * * * *') ;;
    *) fail "Unknown kind of workload: $kind" ;;
  esac
  deployer_kubectl "${create[@]}" --dry-run=client -o yaml -- sleep 3600 | NAMESPACE="$namespace" yq '
    .metadata.namespace = strenv(NAMESPACE) |
    (.. | select(tag == "!!map" and has("containers")) | .containers[].securityContext) = {
      "runAsNonRoot": true,
      "runAsUser": 10001,
      "allowPrivilegeEscalation": false,
      "capabilities": {"drop": ["ALL"]}
    }'
}

# --- Local build --------------------------------------------------------------

# Scenarios that build an image outside of the pipeline use a BuildKit builder
# of their own. The default Docker driver cannot output an OCI layout.
LOCAL_BUILDER="testbed"

# Builds example-app for linux/amd64 as an OCI layout into the given directory.
# Further arguments are passed to "docker buildx build", e.g. --build-arg.
local_build() {
  local layout="$1"
  shift
  docker buildx inspect "$LOCAL_BUILDER" >/dev/null 2>&1 ||
    docker buildx create --name "$LOCAL_BUILDER" --driver docker-container \
      --driver-opt "image=$BUILDKIT_IMAGE" >/dev/null
  rm -rf "$layout" "$layout.tar"
  docker buildx build --builder "$LOCAL_BUILDER" --quiet --platform linux/amd64 \
    --provenance=false --sbom=false "$@" \
    --output "type=oci,dest=$layout.tar" "$EXAMPLE_APP_DIR" >/dev/null
  mkdir -p "$layout"
  tar -xf "$layout.tar" -C "$layout"
}

# --- Legitimate pipeline image ------------------------------------------------

# Copies the image built (and from V1 on signed) by the pipeline for the current
# variant to zot, as deploy.sh does, and prints its reference in the cluster.
# Used by scenarios whose attack starts from a legitimate image, so that a denial
# can only be caused by the examined property and not by the signature.
pipeline_image_in_zot() {
  local image="ghcr.io/$GITHUB_OWNER/example-app-$VARIANT"
  local url="https://api.github.com/repos/$GITHUB_OWNER/example-app/actions/workflows/$VARIANT.yml/runs?branch=main&status=success&per_page=1"
  local commit tag digest
  commit="$(curl -fsSL "$url" | jq -r '.workflow_runs[0].head_sha // empty')"
  [ -n "$commit" ] || fail "No successful run of $VARIANT.yml on main found."
  tag="$commit"
  [ "$VARIANT" = v0 ] && tag=latest
  digest="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$image:$tag")"
  oras cp --recursive --from-registry-config "$ORAS_AUTH_FILE" --to-registry-config "$ORAS_AUTH_FILE" \
    "$image@$digest" "$ZOT_HOST_ADDRESS/example-app-$VARIANT:$tag" >/dev/null
  echo "$ZOT_CLUSTER_ADDRESS/example-app-$VARIANT@$digest"
}

# --- Run and classify an attack -----------------------------------------------

# Applies a manifest with the permissions of the deployer and classifies the result.
# Sets RESULT (allowed, admission-denied or rbac-denied) and DETAIL.
# shellcheck disable=SC2034 # both are read by the scenario scripts
try_apply() {
  local manifest="$1"
  local output
  if output="$(deployer_kubectl apply -f "$manifest" 2>&1)"; then
    RESULT=allowed
    DETAIL=""
  elif grep -q 'admission webhook' <<<"$output"; then
    RESULT=admission-denied
    DETAIL="$(sed -n 's/.*failed: //p' <<<"$output" | head -n 1)"
  elif grep -q 'cannot [a-z]* resource' <<<"$output"; then
    RESULT=rbac-denied
    DETAIL="$(sed -n 's/.*forbidden: //p' <<<"$output" | head -n 1)"
  else
    fail "Unexpected response from the cluster: $output"
  fi
}

remove_manifest() {
  deployer_kubectl delete -f "$1" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# Checks as the deployer whether an action is allowed (kubectl auth can-i). For
# attacks that are supposed to fail at the permission assignment, regardless of
# whether the target object exists in the variant. An empty namespace checks
# cluster-wide or in the namespace of the deployer. Sets RESULT and DETAIL.
# shellcheck disable=SC2034 # both are read by the scenario scripts
try_permission() {
  local verb="$1"
  local resource="$2"
  local namespace="$3"
  local args=(auth can-i "$verb" "$resource")
  [ -n "$namespace" ] && args+=(--namespace "$namespace")
  if deployer_kubectl "${args[@]}" >/dev/null 2>&1; then
    RESULT=allowed
    DETAIL="deployer may $verb $resource"
  else
    RESULT=rbac-denied
    DETAIL="deployer may not $verb $resource"
  fi
}

# --- Results ------------------------------------------------------------------

csv_field() {
  local value="${1//$'\n'/ }"
  printf '"%s"' "${value//\"/\"\"}"
}

repo_state() {
  local repo state=()
  for repo in testbed secure-workflows example-app; do
    state+=("$repo@$(git -C "$TESTBED_DIR/../$repo" rev-parse --short HEAD)")
  done
  echo "${state[*]}"
}

record_result() {
  local ak="$1"
  local case="$2"
  local result="$3"
  local detail="$4"
  local artifact="$5"

  [ -f "$RESULTS_FILE" ] || echo "$RESULTS_HEADER" > "$RESULTS_FILE"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$VARIANT" "$ak" "$case" "$result" \
    "$(csv_field "$detail")" "$(csv_field "$artifact")" "$(csv_field "$(repo_state)")" \
    >> "$RESULTS_FILE"

  info "Result: $result${detail:+ ($detail)}"
}

# =============================================================================
# Helpers for the scenarios that really attack via GitHub (AK-02/03, 05, 06,
# 10a, 11). A push to main builds all four variants at once, but the local
# cluster only runs one variant. Hence the first "make scenario" attacks once for
# real, records the build result and the commit to deploy per variant, restores
# immediately and then evaluates the running variant. Every further call (other
# variant) only reads the state and evaluates against its cluster. The state
# lives under results/ and survives "make down". ATTACK=new attacks again.
# =============================================================================

EXAMPLE_APP_REPO="$GITHUB_OWNER/example-app"
# shellcheck disable=SC2034 # read by the scenario scripts (AK-06 case 2, AK-02/03)
SECURE_WORKFLOWS_REPO="$GITHUB_OWNER/secure-workflows"
STATE_DIR="$TESTBED_DIR/results/state"

# --- Prerequisites ------------------------------------------------------------

# Checks that the GitHub CLI is logged in and the active account is the expected one.
github_scenario_guard() {
  command -v gh >/dev/null || fail "This scenario needs the GitHub CLI 'gh'."
  gh auth status --active >/dev/null 2>&1 || fail "gh is not logged in. Run 'gh auth login' first."
  local active
  active="$(gh api user --jq .login 2>/dev/null || true)"
  [ "$active" = "$GITHUB_OWNER" ] ||
    fail "Active gh account is '${active:-unknown}', expected '$GITHUB_OWNER'. Switch with 'gh auth switch'."
}

# --- Start runs and wait for them ---------------------------------------------

# Waits until a run has completed and prints its result (conclusion).
wait_for_run() {
  local repo="$1" run_id="$2"
  until [ "$(gh run view "$run_id" --repo "$repo" --json status --jq .status)" = completed ]; do
    sleep 10
  done
  gh run view "$run_id" --repo "$repo" --json conclusion --jq .conclusion
}

# Reads result, commit and failed steps of a run into variables.
# shellcheck disable=SC2034 # RUN_* are read by the scenario scripts
fill_run_outputs() {
  local repo="$1" run_id="$2"
  RUN_CONCLUSION="$(wait_for_run "$repo" "$run_id")"
  RUN_HEAD_SHA="$(gh run view "$run_id" --repo "$repo" --json headSha --jq .headSha)"
  RUN_FAILED_STEPS="$(gh run view "$run_id" --repo "$repo" --json jobs \
    --jq '[.jobs[].steps[] | select(.conclusion == "failure") | .name] | join("; ")')"
}

# Starts a workflow run by hand (workflow_dispatch) on a branch and waits for it
# to finish. Sets RUN_ID, RUN_CONCLUSION, RUN_HEAD_SHA, RUN_FAILED_STEPS.
dispatch_and_wait() {
  local variant="$1" ref="$2"
  local repo="$EXAMPLE_APP_REPO" workflow="$1.yml"
  local before
  before="$(gh run list --repo "$repo" --workflow "$workflow" --branch "$ref" -L 1 --json databaseId --jq '.[0].databaseId // 0')"
  gh workflow run "$workflow" --repo "$repo" --ref "$ref" >/dev/null
  RUN_ID="$before"
  until [ -n "$RUN_ID" ] && [ "$RUN_ID" != "$before" ]; do
    sleep 5
    RUN_ID="$(gh run list --repo "$repo" --workflow "$workflow" --branch "$ref" -L 1 --json databaseId --jq '.[0].databaseId // 0')"
  done
  fill_run_outputs "$repo" "$RUN_ID"
}

# Waits for the run of a variant that a push triggered for a given commit.
# Sets the same variables as dispatch_and_wait.
wait_for_push_run() {
  local variant="$1" commit="$2"
  local repo="$EXAMPLE_APP_REPO"
  RUN_ID=""
  until [ -n "$RUN_ID" ]; do
    sleep 5
    RUN_ID="$(gh run list --repo "$repo" --workflow "$variant.yml" --commit "$commit" -L 1 --json databaseId --jq '.[0].databaseId // empty')"
  done
  fill_run_outputs "$repo" "$RUN_ID"
}

# --- Deployment of a given commit ---------------------------------------------

# Renders the regular deployment manifest of a commit with the image reference
# set (like scripts/deploy.sh, but for a freely chosen commit).
render_app_deployment() {
  local commit="$1" image="$2"
  git -C "$EXAMPLE_APP_DIR" show "$commit:k8s/deployment.yaml" | IMAGE="$image" yq '
    (.spec.template.spec.containers[0].image = strenv(IMAGE)) |
    (.spec.template.spec.containers[0].env[] | select(.name == "DEPLOYED_IMAGE") | .value) = strenv(IMAGE)
  '
}

# Copies the image the pipeline built for a given commit to zot and prints its
# cluster reference. Unlike pipeline_image_in_zot the commit can be chosen
# freely, so that the image produced by an attack run can be sent against the
# admission on purpose. V0 via a tag (no digest).
# shellcheck disable=SC2034 # DEPLOY_IMAGE is read by the scenario script
deploy_commit_to_cluster() {
  local variant="$1" commit="$2" tag="${3:-$2}"
  local ghcr="ghcr.io/$GITHUB_OWNER/example-app-$variant" zot_repo="example-app-$variant"
  local digest
  digest="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$ghcr:$tag")"
  oras cp --recursive --from-registry-config "$ORAS_AUTH_FILE" --to-registry-config "$ORAS_AUTH_FILE" \
    "$ghcr@$digest" "$ZOT_HOST_ADDRESS/$zot_repo:$tag" >/dev/null
  if [ "$variant" = v0 ]; then
    DEPLOY_IMAGE="$ZOT_CLUSTER_ADDRESS/$zot_repo:$tag"
  else
    DEPLOY_IMAGE="$ZOT_CLUSTER_ADDRESS/$zot_repo@$digest"
  fi
}

# Evaluates the recorded attack against the running variant: if no image was
# produced, the attack counts as stopped in the pipeline; otherwise the image of
# this commit is deployed and checked at admission.
evaluate_from_state() {
  local ak="$1" case="$2" state_name="$3"
  load_variant_state "$state_name"

  if [ "$SV_RESULT" = build-aborted ]; then
    RESULT=build-aborted
    record_result "$ak" "$case" "$RESULT" "$SV_NOTE" "no image built"
    return
  fi

  step "Deploy the image of the attack (commit ${SV_DEPLOY:0:7}) as the deployer"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin >/dev/null 2>&1 || true
  deploy_commit_to_cluster "$VARIANT" "$SV_DEPLOY" "$SV_TAG"
  info "Image in the cluster: $DEPLOY_IMAGE"
  local manifest="$SCENARIO_DIR/$case.yaml"
  render_app_deployment "$SV_DEPLOY" "$DEPLOY_IMAGE" > "$manifest"
  try_apply "$manifest"
  record_result "$ak" "$case" "$RESULT" "$DETAIL" "$DEPLOY_IMAGE"
  remove_manifest "$manifest"
}

# --- State of the one-off attack ----------------------------------------------

STATE_FILE=""

# Creates a fresh state file for a scenario.
init_attack_state() {
  STATE_FILE="$STATE_DIR/$1.env"
  mkdir -p "$STATE_DIR"
  : > "$STATE_FILE"
}

# Records for one variant what the attack produced: the build result (built or
# build-aborted), the commit to deploy including its tag, and a note.
set_variant_state() {
  local v="$1"
  printf 'STATE_%s_RESULT=%q\nSTATE_%s_DEPLOY=%q\nSTATE_%s_TAG=%q\nSTATE_%s_NOTE=%q\n' \
    "$v" "$2" "$v" "$3" "$v" "$4" "$v" "$5" >> "$STATE_FILE"
}

# True if an attack has already run for this scenario (unless ATTACK=new).
attack_done() {
  [ -f "$STATE_DIR/$1.env" ] && [ "${ATTACK:-}" != new ]
}

# Reads the state of the running variant into SV_RESULT, SV_DEPLOY, SV_TAG, SV_NOTE.
load_variant_state() {
  # shellcheck source=/dev/null
  source "$STATE_DIR/$1.env"
  eval "SV_RESULT=\${STATE_${VARIANT}_RESULT:-}"
  eval "SV_DEPLOY=\${STATE_${VARIANT}_DEPLOY:-}"
  eval "SV_TAG=\${STATE_${VARIANT}_TAG:-}"
  eval "SV_NOTE=\${STATE_${VARIANT}_NOTE:-}"
}

# --- Pull requests and restore ------------------------------------------------

# Opens a PR for a branch with already committed changes, merges it as a merge
# commit and pulls main. Provides the merge commit (MERGE_COMMIT).
# shellcheck disable=SC2034 # MERGE_COMMIT is read by the scenario script
open_and_merge_pr() {
  local repo="$1" branch="$2" title="$3" dir="$4"
  git -C "$dir" push --quiet origin "$branch"
  gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body "$title" >/dev/null
  gh pr merge "$branch" --repo "$repo" --merge --delete-branch >/dev/null
  git -C "$dir" switch --quiet main
  git -C "$dir" pull --quiet --ff-only origin main
  MERGE_COMMIT="$(git -C "$dir" rev-parse HEAD)"
}

# =============================================================================
# Driver for the scenarios that bring the attack in via a signed commit on
# example-app/main (AK-05 case b, AK-06 case 1, AK-10a, AK-11).
# gitsign needs a browser login that Claude cannot perform itself. The driver
# prepares the change and prints the exact commit command for Lukas; after
# signing, the same call opens the PR, evaluates the builds and restores via a
# revert (also a signed commit). The state is kept in results/state/<ak>.phase,
# so that "make scenario" continues the same procedure on repeated calls.
# =============================================================================

# Prints the exact command that has to be run and how to continue.
print_sign_prompt() {
  local branch="$1" title="$2" ak="$3"
  step "Signed commit required"
  info "The change is ready on branch '$branch' (not committed yet)."
  info "Please commit it signed (opens the browser login of gitsign):"
  printf '\n    ! git -C %s commit -m "%s"\n\n' "$EXAMPLE_APP_DIR" "$title"
  info "Then run again: make scenario AK=${ak}"
}

# True if the branch holds a signed commit ahead of origin/main.
has_signed_commit() {
  local branch="$1"
  git -C "$EXAMPLE_APP_DIR" rev-parse --quiet --verify "$branch" >/dev/null || return 1
  [ "$(git -C "$EXAMPLE_APP_DIR" rev-list --count "origin/main..$branch")" -ge 1 ] || return 1
  git -C "$EXAMPLE_APP_DIR" cat-file commit "$branch" | grep '^gpgsig' >/dev/null
}

# Creates the attack branch and lets the preparation function change the files.
# Nothing is committed (that is done signed by Lukas).
prepare_attack_branch() {
  local branch="$1" prepare_fn="$2"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  git -C "$EXAMPLE_APP_DIR" switch --quiet -C "$branch" origin/main
  "$prepare_fn"
  git -C "$EXAMPLE_APP_DIR" add -A
}

# Creates the revert branch and prepares reverting the merge commit.
prepare_revert_branch() {
  local branch="$1" merge="$2"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  git -C "$EXAMPLE_APP_DIR" switch --quiet -C "$branch" origin/main
  git -C "$EXAMPLE_APP_DIR" revert --no-commit -m 1 "$merge"
}

# Waits per variant for the push run triggered by the merge and records how the
# attack has to be evaluated. What matters is not the result of the run but
# whether an image is in ghcr: a step failing late (e.g. the vulnerability gate
# in V3) leaves an unsigned image behind that then has to be checked at
# admission. If the build stops before the push (e.g. the commit verification),
# no image is produced and the attack counts as defended.
record_push_builds() {
  local state_name="$1" merge="$2" variant image
  init_attack_state "$state_name"
  for variant in v0 v1 v2 v3; do
    step "Wait for the push run of $variant.yml for ${merge:0:7}"
    wait_for_push_run "$variant" "$merge"
    info "Run $RUN_ID: $RUN_CONCLUSION"
    image="ghcr.io/$GITHUB_OWNER/example-app-$variant"
    if oras resolve --registry-config "$ORAS_AUTH_FILE" "$image:$merge" >/dev/null 2>&1; then
      set_variant_state "$variant" built "$merge" "$merge" "build $RUN_CONCLUSION, image in ghcr"
    else
      set_variant_state "$variant" build-aborted "" "" "step: ${RUN_FAILED_STEPS:-aborted before the push}"
    fi
  done
}

# Checks that all variants build green again after the revert (pipeline usable).
verify_restore_green() {
  local merge="$1" variant
  for variant in v1 v2 v3; do
    step "Check the restore: $variant.yml for ${merge:0:7}"
    wait_for_push_run "$variant" "$merge"
    [ "$RUN_CONCLUSION" = success ] ||
      fail "After the revert $variant.yml fails (run $RUN_ID). main is still blocked."
    info "Run $RUN_ID: success"
  done
}

# The actual state machine. EVALUATE_FN evaluates one variant from the stored
# state (see evaluate_from_state or scenario-specific).
run_signed_app_scenario() {
  local state_name="$1" branch="$2" title="$3" prepare_fn="$4" evaluate_fn="$5"
  local phase_file="$STATE_DIR/$state_name.phase"
  mkdir -p "$STATE_DIR"

  local PHASE=fresh
  # shellcheck source=/dev/null
  [ -f "$phase_file" ] && source "$phase_file"
  [ "${ATTACK:-}" = new ] && PHASE=fresh

  if [ "$PHASE" = fresh ]; then
    step "Prepare the attack: $title"
    prepare_attack_branch "$branch" "$prepare_fn"
    printf 'PHASE=attack-prepared\n' > "$phase_file"
    print_sign_prompt "$branch" "$title" "$AK_FLAG"
    exit 0
  fi

  if [ "$PHASE" = attack-prepared ]; then
    if ! has_signed_commit "$branch"; then
      print_sign_prompt "$branch" "$title" "$AK_FLAG"
      exit 0
    fi
    step "Bring the attack to main (PR + merge)"
    open_and_merge_pr "$EXAMPLE_APP_REPO" "$branch" "$title" "$EXAMPLE_APP_DIR"
    record_push_builds "$state_name" "$MERGE_COMMIT"
    step "Prepare the restore (revert)"
    prepare_revert_branch "$branch-revert" "$MERGE_COMMIT"
    printf 'PHASE=restore-prepared\n' > "$phase_file"
    print_sign_prompt "$branch-revert" "Revert: $title" "$AK_FLAG"
    exit 0
  fi

  if [ "$PHASE" = restore-prepared ]; then
    if ! has_signed_commit "$branch-revert"; then
      print_sign_prompt "$branch-revert" "Revert: $title" "$AK_FLAG"
      exit 0
    fi
    step "Bring the restore to main (revert PR + merge)"
    open_and_merge_pr "$EXAMPLE_APP_REPO" "$branch-revert" "Revert: $title" "$EXAMPLE_APP_DIR"
    verify_restore_green "$MERGE_COMMIT"
    printf 'PHASE=done\n' > "$phase_file"
  fi

  # PHASE=done: only evaluate (also for further variants)
  "$evaluate_fn"
}
