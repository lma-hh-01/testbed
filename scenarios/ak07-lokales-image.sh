#!/usr/bin/env bash
# AK-07: Container-Image ausserhalb der regulaeren Pipeline erstellen.
# Ein Angreifer mit Schreibrecht auf die Registry baut die Anwendung auf seinem
# eigenen Rechner, schiebt das Image direkt nach zot und deployt es mit den
# Rechten des Deployers. Das Image ist inhaltlich unauffaellig, es fehlt nur
# jeder Nachweis, dass es aus der Pipeline stammt.
source "$(dirname "$0")/lib.sh"

AK="AK-07"
CASE="lokal-gebaut"
# Kap. 5 erwartet die Abwehr erst mit der Provenance in V2.
HYPOTHESIS=V2
REPOSITORY="example-app-$VARIANT"
TAG="ak07-lokal"

describe "$AK" "Lokal gebautes Image" \
  "Die Anwendung wird lokal gebaut, direkt nach zot geschoben und per Digest deployt. Hypothese aus Kap. 5: abgewehrt ab V2 (Provenance). Erwartet laut Umsetzung: schon ab V1, weil die Signatur der Pipeline fehlt."

step "Anwendung lokal bauen (ausserhalb der Pipeline)"
layout="$SCENARIO_DIR/ak07-image"
local_build "$layout" --build-arg APP_VARIANT=lokal-gebaut

step "Image als Uploader direkt nach zot schieben"
digest="$(jq -r '.manifests[0].digest' "$layout/index.json")"
oras cp --from-oci-layout --to-registry-config "$ORAS_AUTH_FILE" \
  "$layout@$digest" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG" >/dev/null
image="$ZOT_CLUSTER_ADDRESS/$REPOSITORY@$digest"
info "Image in zot: $image"

step "Lokal gebautes Image als Deployer deployen"
manifest="$SCENARIO_DIR/ak07.yaml"
workload_manifest deployment ak07-lokal "$image" > "$manifest"
try_apply "$manifest"
record_result "$AK" "$CASE" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$image"
remove_manifest "$manifest"
