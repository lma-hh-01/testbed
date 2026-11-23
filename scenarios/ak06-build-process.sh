#!/usr/bin/env bash
# AK-06: Compromise of the build process.
# Two cases:
#   Case 1 (app repo): next to the regular build an additional job runs that
#     builds a manipulated image and signs it with the identity of this app
#     workflow. In V1 that is the expected identity, the image is accepted.
#     From V2 on the build lives in the central workflow; the app job can only
#     sign with the identity of the app repo, which the policy does not expect.
#   Case 2 (central workflow): a step in the build job of secure-workflows tries
#     to sign and fails because this job has no id-token.
#     Proof that build and signing are separated.
#
# Case 1 needs a signed commit on example-app/main (procedure like AK-10a).
# Case 2 runs via a normal PR in secure-workflows (no signature).
source "$(dirname "$0")/lib.sh"

AK="AK-06"
# shellcheck disable=SC2034 # AK_FLAG is read by the driver in lib.sh (re-run hint)
AK_FLAG="06"
BRANCH="ak06-build-process"
TITLE="AK-06: additional job signs a manipulated image"

describe "$AK" "Compromise of the build process" \
  "An additional job in the workflow of the app repo builds a manipulated image and, from V1 on, signs it with the identity of the app workflow."

github_scenario_guard

# --- Case 1: additional signing job in the app repo ---------------------------

# Appends a manipulate job to an app repo workflow. After the regular build it
# builds a manipulated image, stores it under the same tag and (except in V0)
# signs it with the identity of this workflow. The legitimate and the manipulated
# image share the commit tag; because manipulate runs with "needs: build", the
# tag points to the manipulated image in the end.
manipulate_job() {
  local sign="$1"
  cat <<YML

  manipulate:
    needs: build
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
      id-token: write
    steps:
      - uses: actions/checkout@v7
      - uses: docker/setup-buildx-action@v4
      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: \${{ github.actor }}
          password: \${{ secrets.GITHUB_TOKEN }}
      - uses: sigstore/cosign-installer@v4.1.3
      - id: push
        uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/amd64
          push: true
          provenance: false
          sbom: false
          build-args: |
            APP_VARIANT=ak06-manipulated
            APP_COMMIT=\${{ github.sha }}
          tags: \${{ env.IMAGE }}:\${{ github.sha }}
YML
  if [ "$sign" = sign ]; then
    cat <<'YML'
      - name: Sign the manipulated image with the identity of this workflow
        run: cosign sign --yes "${{ env.IMAGE }}@${{ steps.push.outputs.digest }}"
YML
  fi
}

# V2 and V3 call the central workflow; the manipulate job is placed next to it
# (the central call stays). V0 and V1 build in the app repo; there the job is
# appended to the existing workflow.
write_v2v3_with_manipulate() {
  local variant="$1"
  cat > "$EXAMPLE_APP_DIR/.github/workflows/$variant.yml" <<YML
# AK-06 case 1: The regular central call stays, an additional job builds a
# manipulated image and signs it with the identity of this app workflow.
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
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      artifact-metadata: write
    uses: ${GITHUB_OWNER}/secure-workflows/.github/workflows/$variant.yml@main
$(manipulate_job sign)
YML
}

prepare_build_process() {
  manipulate_job "" >> "$EXAMPLE_APP_DIR/.github/workflows/v0.yml"
  manipulate_job sign >> "$EXAMPLE_APP_DIR/.github/workflows/v1.yml"
  write_v2v3_with_manipulate v2
  write_v2v3_with_manipulate v3
  info "Manipulate job appended to v0/v1, placed next to the central call in v2/v3."
}

evaluate_ak06() {
  evaluate_from_state "$AK" app-repo-extra-job ak06
}

run_signed_app_scenario ak06 "$BRANCH" "$TITLE" prepare_build_process evaluate_ak06
