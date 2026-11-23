#!/usr/bin/env bash
# AK-07: Building a container image outside of the regular pipeline.
# An attacker with write access to the registry builds the application on their
# own machine, pushes the image directly to zot and deploys it with the
# permissions of the deployer. The content of the image is inconspicuous, it
# only lacks any proof that it comes from the pipeline.
source "$(dirname "$0")/lib.sh"

AK="AK-07"
CASE="locally-built"
REPOSITORY="example-app-$VARIANT"
TAG="ak07-local"

describe "$AK" "Locally built image" \
  "The application is built locally, pushed directly to zot and deployed by digest."

step "Build the application locally (outside of the pipeline)"
layout="$SCENARIO_DIR/ak07-image"
local_build "$layout" --build-arg APP_VARIANT=locally-built

step "Push the image directly to zot as the uploader"
digest="$(jq -r '.manifests[0].digest' "$layout/index.json")"
oras cp --from-oci-layout --to-registry-config "$ORAS_AUTH_FILE" \
  "$layout@$digest" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG" >/dev/null
image="$ZOT_CLUSTER_ADDRESS/$REPOSITORY@$digest"
info "Image in zot: $image"

step "Deploy the locally built image as the deployer"
manifest="$SCENARIO_DIR/ak07.yaml"
workload_manifest deployment ak07-local "$image" > "$manifest"
try_apply "$manifest"
record_result "$AK" "$CASE" "$RESULT" "$DETAIL" "$image"
remove_manifest "$manifest"
