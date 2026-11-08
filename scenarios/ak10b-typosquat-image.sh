#!/usr/bin/env bash
# AK-10 (Teil b): Typosquatting ueber Image-Namen.
# Ein Angreifer legt unter einem vertippten, populaer aussehenden Namen ein
# eigenes Image in der Registry ab (hier "ngnix" statt "nginx"). Verweist ein
# Deployment versehentlich darauf, laeuft das fremde Image. Dieser Teil von
# AK-10 wird nicht durch das Pinning (AF-11, V3) abgewehrt, sondern bereits durch
# die Signaturpruefung an der Admission (AF-13), weil dem Image die Signatur der
# Pipeline fehlt.
source "$(dirname "$0")/lib.sh"

AK="AK-10"
CASE="typosquat-image"
# Kap. 5 ordnet AK-10 der Variante V3 zu (Dependency Confusion). Der Image-Teil
# wird erwartungsgemaess schon ab V1 abgewehrt, das ist als Abweichung zu zeigen.
HYPOTHESIS=V3
REPOSITORY="ngnix"
TAG="1.27"

describe "$AK" "Typosquat-Image" \
  "Ein fremdes Image wird unter dem vertippten Namen '$REPOSITORY' in zot abgelegt und per Digest deployt. Hypothese aus Kap. 5: abgewehrt ab V3. Erwartet laut Umsetzung: schon ab V1, weil die Signatur der Pipeline fehlt (AF-13, nicht AF-11)."

step "Fremdes Image unter dem vertippten Namen '$REPOSITORY' ablegen"
oras cp --from-registry-config "$ORAS_AUTH_FILE" --to-registry-config "$ORAS_AUTH_FILE" \
  "$ALPINE_IMAGE" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG" >/dev/null
digest="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$ZOT_HOST_ADDRESS/$REPOSITORY:$TAG")"
image="$ZOT_CLUSTER_ADDRESS/$REPOSITORY@$digest"
info "Image in zot: $image"

step "Typosquat-Image als Deployer deployen"
manifest="$SCENARIO_DIR/ak10b.yaml"
workload_manifest deployment ak10b-typosquat "$image" > "$manifest"
try_apply "$manifest"
record_result "$AK" "$CASE" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$image"
remove_manifest "$manifest"
