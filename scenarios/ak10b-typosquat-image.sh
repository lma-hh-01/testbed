#!/usr/bin/env bash
# AK-10 (part b): Typosquatting via image names.
# An attacker stores an image of their own under a misspelled, popular looking
# name in the registry (here "ngnix" instead of "nginx"). If a deployment refers
# to it by mistake, the foreign image runs. This part of AK-10 is not defended
# by pinning (AF-11, V3) but already by the signature verification at admission
# (AF-13), because the image lacks the signature of the pipeline.
source "$(dirname "$0")/lib.sh"

AK="AK-10"
CASE="typosquat-image"
# Chapter 5 assigns AK-10 to variant V3 (dependency confusion). The image part is
# expected to be defended already from V1 on, which is to be shown as a deviation.
HYPOTHESIS=V3
REPOSITORY="ngnix"
TAG="1.27"

describe "$AK" "Typosquat image" \
  "A foreign image is stored in zot under the misspelled name '$REPOSITORY' and deployed by digest. Hypothesis from chapter 5: defended from V3 on. Expected from the implementation: already from V1 on, because the signature of the pipeline is missing (AF-13, not AF-11)."

step "Store a foreign image under the misspelled name '$REPOSITORY'"
oras cp --from-registry-config "$ORAS_AUTH_FILE" --to-registry-config "$ORAS_AUTH_FILE" \
  "$ALPINE_IMAGE" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG" >/dev/null
digest="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG")"
image="$ZOT_CLUSTER_ADDRESS/$REPOSITORY@$digest"
info "Image in zot: $image"

step "Deploy the typosquat image as the deployer"
manifest="$SCENARIO_DIR/ak10b.yaml"
workload_manifest deployment ak10b-typosquat "$image" > "$manifest"
try_apply "$manifest"
record_result "$AK" "$CASE" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$image"
remove_manifest "$manifest"
