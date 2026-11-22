#!/usr/bin/env bash
# AK-08: Artifact manipulation after the build.
# An attacker takes the image signed by the pipeline, changes its content and
# copies the valid original signature onto the changed image. Because signature
# and digest are bound to each other (AF-09), the signature does not cover the
# new content: the verification at admission fails.
source "$(dirname "$0")/lib.sh"

AK="AK-08"
CASE="signature-transplanted"
HYPOTHESIS=V1
AUTH="$ORAS_AUTH_FILE"
HOST_REPO="$ZOT_HOST_ADDRESS/example-app-$VARIANT"

describe "$AK" "Signature copied onto a tampered image" \
  "The signed image is changed and gets the original signature attached. Expected: in V0 it runs (no verification), from V1 on the admission denies it, because the signature does not cover the changed digest."

step "Provide the legitimate, signed image of the variant"
orig_ref="$(pipeline_image_in_zot)"
orig="${orig_ref##*@}"
info "Original: $orig"

step "Change the content of the image (manipulated build)"
layout="$SCENARIO_DIR/ak08-image"
local_build "$layout" --build-arg APP_VARIANT=manipulated
mod="$(jq -r '.manifests[0].digest' "$layout/index.json")"
oras cp --from-oci-layout --to-registry-config "$AUTH" "$layout@$mod" "$HOST_REPO:ak08" >/dev/null
info "Manipulated: $mod"

step "Move the original signature onto the manipulated image"
sig="$(oras discover --registry-config "$AUTH" --format json "$HOST_REPO@$orig" |
  jq -r '[.referrers[] | select(.artifactType | startswith("application/vnd.dev.sigstore.bundle"))][0].digest // empty')"
if [ -n "$sig" ]; then
  mod_size="$(oras manifest fetch --registry-config "$AUTH" "$HOST_REPO@$mod" | wc -c | tr -d ' ')"
  oras manifest fetch --registry-config "$AUTH" "$HOST_REPO@$sig" |
    jq -c --arg d "$mod" --argjson s "$mod_size" \
      '.subject = {mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $d, size: $s}' \
      > "$SCENARIO_DIR/ak08-sig.json"
  oras manifest push --registry-config "$AUTH" "$HOST_REPO:ak08-sig" \
    --media-type application/vnd.oci.image.manifest.v1+json "$SCENARIO_DIR/ak08-sig.json" >/dev/null
  info "Signature attached. It still only covers the original."
else
  info "The original carries no signature (variant without mandatory signatures), nothing to move."
fi

step "Deploy the manipulated image with the attached signature"
image="$ZOT_CLUSTER_ADDRESS/example-app-$VARIANT@$mod"
manifest="$SCENARIO_DIR/ak08.yaml"
workload_manifest deployment ak08-manipulated "$image" > "$manifest"
try_apply "$manifest"
record_result "$AK" "$CASE" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$image"
remove_manifest "$manifest"
