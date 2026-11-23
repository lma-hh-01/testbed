#!/usr/bin/env bash
# AK-05: Manipulation of the build input parameters.
# Two cases:
#   (a) feature-branch: the attacker starts the build from an unofficial branch
#       instead of main (workflow_dispatch). In V0 its image ends up in the
#       cluster, from V1 on the build stops at the step "Build main only".
#   (b) own-build-steps: the attacker changes the build on main. In V1 the
#       workflow lives in the app repo, the injected step is signed along and
#       allowed. From V2 on the build lives in the central workflow, the app
#       repo can no longer change it.
#
# Model "attack once, evaluate per variant": the first call attacks once for
# real via GitHub, records the result per variant and restores. Every further
# call only evaluates the currently running variant. ATTACK=new forces a new
# attack.
source "$(dirname "$0")/lib.sh"

AK="AK-05"
# shellcheck disable=SC2034 # AK_FLAG is read by the driver in lib.sh (re-run hint)
AK_FLAG="05"
FEATURE_BRANCH="ak05-feature-branch"
INJECTED_VARIANT="ak05b-injected"

describe "$AK" "Manipulation of the build input parameters" \
  "Case (a): build from an unofficial feature branch via workflow_dispatch (feature-branch). Case (b): own build steps on main (own-build-steps)."

github_scenario_guard

# --- Case (a): build from an unofficial feature branch ------------------------

# Attacks once: creates the feature branch and starts a build there for each
# variant. V0 builds through, from V1 on the step "Build main only" stops it.
# The result per variant is recorded, the branch stays as an attack artifact
# (it cannot change main: no build on main, no merge without a signature).
attack_feature_branch() {
  step "Case (a): attack via the unofficial branch '$FEATURE_BRANCH'"
  init_attack_state ak05a

  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  git -C "$EXAMPLE_APP_DIR" switch --quiet -C "$FEATURE_BRANCH" origin/main
  # A commit of its own, deliberately unsigned, makes the branch build
  # distinguishable from the main build. It is never merged and never verified
  # (from V1 on the build stops before any verification, V0 does not verify).
  git -C "$EXAMPLE_APP_DIR" -c commit.gpgsign=false commit --quiet --allow-empty \
    -m "AK-05: build from an unofficial feature branch"
  git -C "$EXAMPLE_APP_DIR" push --quiet --force origin "$FEATURE_BRANCH"
  local branch_sha
  branch_sha="$(git -C "$EXAMPLE_APP_DIR" rev-parse HEAD)"
  git -C "$EXAMPLE_APP_DIR" switch --quiet main
  info "Branch commit: ${branch_sha:0:7} (unsigned)"

  local variant
  for variant in v0 v1 v2 v3; do
    step "Case (a): start $variant.yml on '$FEATURE_BRANCH'"
    dispatch_and_wait "$variant" "$FEATURE_BRANCH"
    info "Run $RUN_ID: $RUN_CONCLUSION"
    if [ "$RUN_CONCLUSION" = success ]; then
      set_variant_state "$variant" built "$branch_sha" "$branch_sha" "branch build succeeded"
    else
      set_variant_state "$variant" build-aborted "" "" "step: ${RUN_FAILED_STEPS:-unknown}"
    fi
  done
}

attack_done ak05a || attack_feature_branch
evaluate_from_state "$AK" feature-branch ak05a

# --- Case (b): own build steps on main ---------------------------------------

# Writes an attacker workflow that replaces the central call with a build job of
# its own: the image is built and pushed in the app repo, but not signed with the
# identity of the central workflow.
write_own_build_job() {
  local variant="$1"
  cat > "$EXAMPLE_APP_DIR/.github/workflows/$variant.yml" <<YML
# AK-05b: The central call is replaced by a build job of its own. The image is
# built and pushed in the application repository, but not signed with the
# identity of the central workflow.
name: $variant

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions: {}

env:
  IMAGE: ghcr.io/\${{ github.repository }}-$variant

jobs:
  build:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7

      - uses: docker/setup-buildx-action@v4

      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: \${{ github.actor }}
          password: \${{ secrets.GITHUB_TOKEN }}

      - name: Record build time
        run: echo "BUILD_TIME=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "\$GITHUB_ENV"

      - uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/amd64
          push: true
          provenance: false
          sbom: false
          build-args: |
            APP_VARIANT=$INJECTED_VARIANT
            APP_COMMIT=\${{ github.sha }}
            APP_BUILD_TIME=\${{ env.BUILD_TIME }}
          labels: |
            org.opencontainers.image.source=\${{ github.server_url }}/\${{ github.repository }}
          tags: \${{ env.IMAGE }}:\${{ github.sha }}
YML
}

# Manipulates the build parameter of a variant that builds in the app repo.
inject_build_arg() {
  local file="$EXAMPLE_APP_DIR/.github/workflows/$1.yml" variant="$1"
  sed "s/APP_VARIANT=$variant/APP_VARIANT=$INJECTED_VARIANT/" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# V0 and V1 build in the app repo: a manipulated build parameter is enough, the
# image is signed (in V1) with the expected identity and accepted at admission.
# V2 and V3 build centrally: in the app repo the attacker can only replace the
# call, and the image built that way does not carry the central signature.
prepare_own_build_steps() {
  inject_build_arg v0
  inject_build_arg v1
  write_own_build_job v2
  write_own_build_job v3
  info "Build parameter manipulated in v0/v1, central call replaced in v2/v3."
}

evaluate_ak05b() {
  evaluate_from_state "$AK" own-build-steps ak05b
}

run_signed_app_scenario ak05b ak05-own-build-steps \
  "AK-05b: own build steps on main (replace the central call)" \
  prepare_own_build_steps evaluate_ak05b
