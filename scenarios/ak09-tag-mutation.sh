#!/usr/bin/env bash
# AK-09: Registry-Manipulation durch Tag-Mutation.
# Ein Angreifer mit Schreibrecht auf die Registry haengt einen vorhandenen Tag
# von einem Image auf ein untergeschobenes um. Wer das Image ueber den Tag
# bezieht, erhaelt danach das untergeschobene. Die Gegenmassnahme ist die
# Referenzierung ueber den unveraenderlichen Digest (AF-10), die ab V1 an der
# Admission erzwungen wird.
source "$(dirname "$0")/lib.sh"

AK="AK-09"
CASE="tag-umgehaengt"
HYPOTHESIS=V1
REPOSITORY="example-app-$VARIANT"
TAG="ak09"

describe "$AK" "Tag-Mutation in zot" \
  "Ein vorhandener Tag wird auf ein untergeschobenes Image umgehaengt und das Deployment ueber diesen Tag versucht. Erwartet: In V0 laeuft das untergeschobene Image, weil ueber den Tag deployt wird. Ab V1 lehnt Kyverno die Tag-Referenz ab und verlangt einen Digest."

step "Urspruengliches Image unter dem Tag '$TAG' ablegen"
oras cp --from-registry-config "$ORAS_AUTH_FILE" --to-registry-config "$ORAS_AUTH_FILE" \
  "$ALPINE_IMAGE" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG" >/dev/null
before="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG")"
info "Digest vorher: $before"

step "Untergeschobenes Image lokal bauen und denselben Tag darauf umhaengen"
layout="$SCENARIO_DIR/ak09-image"
local_build "$layout" --build-arg APP_VARIANT=implantiert
implanted="$(jq -r '.manifests[0].digest' "$layout/index.json")"
oras cp --from-oci-layout --to-registry-config "$ORAS_AUTH_FILE" \
  "$layout@$implanted" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG" >/dev/null
after="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG")"
info "Digest nachher: $after"
[ "$before" != "$after" ] || fail "Der Tag zeigt unveraendert auf dasselbe Image."
info "Der Tag zeigt jetzt auf das untergeschobene Image."

step "Deployment ueber den (umgehaengten) Tag versuchen"
manifest="$SCENARIO_DIR/ak09.yaml"
workload_manifest deployment ak09-tag "$ZOT_CLUSTER_ADDRESS/$REPOSITORY:$TAG" > "$manifest"
try_apply "$manifest"
record_result "$AK" "$CASE" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$ZOT_CLUSTER_ADDRESS/$REPOSITORY:$TAG"
remove_manifest "$manifest"
