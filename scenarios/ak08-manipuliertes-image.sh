#!/usr/bin/env bash
# AK-08: Artefakt-Manipulation nach dem Build.
# Ein Angreifer nimmt das von der Pipeline signierte Image, veraendert seinen
# Inhalt und kopiert die gueltige Original-Signatur auf das veraenderte Image.
# Weil Signatur und Digest aneinander gebunden sind (AF-09), deckt die Signatur
# den neuen Inhalt nicht ab: Die Pruefung an der Admission schlaegt fehl.
source "$(dirname "$0")/lib.sh"

AK="AK-08"
CASE="signatur-transplantiert"
HYPOTHESIS=V1
AUTH="$ORAS_AUTH_FILE"
HOST_REPO="$ZOT_HOST_ADDRESS/example-app-$VARIANT"

describe "$AK" "Signatur auf manipuliertes Image kopiert" \
  "Das signierte Image wird veraendert und bekommt die Original-Signatur angehaengt. Erwartet: In V0 laeuft es (keine Pruefung), ab V1 lehnt die Admission ab, weil die Signatur den veraenderten Digest nicht abdeckt."

step "Legitimes, signiertes Image der Variante bereitstellen"
orig_ref="$(pipeline_image_in_zot)"
orig="${orig_ref##*@}"
info "Original: $orig"

step "Inhalt des Images veraendern (manipulierter Build)"
layout="$SCENARIO_DIR/ak08-image"
local_build "$layout" --build-arg APP_VARIANT=manipuliert
mod="$(jq -r '.manifests[0].digest' "$layout/index.json")"
oras cp --from-oci-layout --to-registry-config "$AUTH" "$layout@$mod" "$HOST_REPO:ak08" >/dev/null
info "Manipuliert: $mod"

step "Original-Signatur auf das manipulierte Image umhaengen"
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
  info "Signatur angehaengt. Sie deckt weiterhin nur das Original ab."
else
  info "Das Original traegt keine Signatur (Variante ohne Signaturpflicht), nichts umzuhaengen."
fi

step "Manipuliertes Image mit angehaengter Signatur deployen"
image="$ZOT_CLUSTER_ADDRESS/example-app-$VARIANT@$mod"
manifest="$SCENARIO_DIR/ak08.yaml"
workload_manifest deployment ak08-manipuliert "$image" > "$manifest"
try_apply "$manifest"
record_result "$AK" "$CASE" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$image"
remove_manifest "$manifest"
