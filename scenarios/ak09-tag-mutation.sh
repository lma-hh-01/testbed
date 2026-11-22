#!/usr/bin/env bash
# AK-09: Registry manipulation by tag mutation.
# An attacker with write access to the registry moves an existing tag from one
# image to a planted one. Whoever pulls the image by the tag afterwards gets the
# planted one. The countermeasure is referencing by the immutable digest
# (AF-10), which is enforced at admission from V1 on.
source "$(dirname "$0")/lib.sh"

AK="AK-09"
CASE="tag-moved"
HYPOTHESIS=V1
REPOSITORY="example-app-$VARIANT"
TAG="ak09"

describe "$AK" "Tag mutation in zot" \
  "An existing tag is moved to a planted image and the deployment is attempted via this tag. Expected: in V0 the planted image runs, because the deployment uses the tag. From V1 on Kyverno denies the tag reference and requires a digest."

step "Store the original image under the tag '$TAG'"
oras cp --from-registry-config "$ORAS_AUTH_FILE" --to-registry-config "$ORAS_AUTH_FILE" \
  "$ALPINE_IMAGE" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG" >/dev/null
before="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG")"
info "Digest before: $before"

step "Build the planted image locally and move the same tag onto it"
layout="$SCENARIO_DIR/ak09-image"
local_build "$layout" --build-arg APP_VARIANT=implanted
implanted="$(jq -r '.manifests[0].digest' "$layout/index.json")"
oras cp --from-oci-layout --to-registry-config "$ORAS_AUTH_FILE" \
  "$layout@$implanted" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG" >/dev/null
after="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG")"
info "Digest after: $after"
[ "$before" != "$after" ] || fail "The tag still points to the same image."
info "The tag now points to the planted image."

step "Attempt the deployment via the (moved) tag"
manifest="$SCENARIO_DIR/ak09.yaml"
workload_manifest deployment ak09-tag "$ZOT_CLUSTER_ADDRESS/$REPOSITORY:$TAG" > "$manifest"
try_apply "$manifest"
record_result "$AK" "$CASE" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$ZOT_CLUSTER_ADDRESS/$REPOSITORY:$TAG"
remove_manifest "$manifest"
