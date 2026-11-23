#!/usr/bin/env bash
# AK-14: Insecure configuration of Kubernetes resources.
# An attacker deploys the regular, signed image, but with an insecure pod
# configuration (privileged, as root, with privilege escalation, in the host
# network). The image passes the signature verification, the attack can only be
# defended by checking the configuration itself (AF-15), which V3 adds.
source "$(dirname "$0")/lib.sh"

AK="AK-14"

describe "$AK" "Insecure pod configuration" \
  "The signed image is deployed with an insecure pod configuration (privileged, as root, with privilege escalation, in the host network)."

step "Provide the signed image of the variant"
IMAGE="$(pipeline_image_in_zot)"
info "Image: $IMAGE"

attack() {
  local case="$1"
  local patch="$2"
  local manifest="$SCENARIO_DIR/ak14-$case.yaml"

  step "Case '$case'"
  workload_manifest pod "ak14-$case" "$IMAGE" | yq "$patch" > "$manifest"
  try_apply "$manifest"
  record_result "$AK" "$case" "$RESULT" "$DETAIL" "$IMAGE"
  remove_manifest "$manifest"
}

# Privileged requires allowPrivilegeEscalation!=false, otherwise the Kubernetes
# API already rejects the manifest. The attacker sets both consistently.
attack privileged             '.spec.containers[0].securityContext.privileged = true | .spec.containers[0].securityContext.allowPrivilegeEscalation = true'
attack run-as-root            '.spec.containers[0].securityContext.runAsNonRoot = false | .spec.containers[0].securityContext.runAsUser = 0'
attack privilege-escalation   '.spec.containers[0].securityContext.allowPrivilegeEscalation = true'
attack host-network           '.spec.hostNetwork = true'
