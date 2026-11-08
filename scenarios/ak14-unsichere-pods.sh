#!/usr/bin/env bash
# AK-14: Unsichere Konfiguration von Kubernetes-Ressourcen.
# Ein Angreifer deployt das regulaere, signierte Image, aber mit einer unsicheren
# Pod-Konfiguration (privilegiert, als root, mit Rechteausweitung, im Host-Netz).
# Das Image besteht die Signaturpruefung, abgewehrt werden kann der Angriff nur
# ueber eine Pruefung der Konfiguration selbst (AF-15), die V3 ergaenzt.
source "$(dirname "$0")/lib.sh"

AK="AK-14"
HYPOTHESIS=V3

describe "$AK" "Unsichere Pod-Konfiguration" \
  "Das signierte Image wird mit einer unsicheren Pod-Konfiguration deployt. Erwartet: Bis V2 laesst die Admission das durch, weil nur das Image geprueft wird. Ab V3 lehnt die Pod-Sicherheitsrichtlinie die Konfiguration ab."

step "Signiertes Image der Variante bereitstellen"
IMAGE="$(pipeline_image_in_zot)"
info "Image: $IMAGE"

attack() {
  local case="$1"
  local patch="$2"
  local manifest="$SCENARIO_DIR/ak14-$case.yaml"

  step "Fall '$case'"
  workload_manifest pod "ak14-$case" "$IMAGE" | yq "$patch" > "$manifest"
  try_apply "$manifest"
  record_result "$AK" "$case" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$IMAGE"
  remove_manifest "$manifest"
}

# Privilegiert erzwingt allowPrivilegeEscalation!=false, sonst weist schon die
# Kubernetes-API das Manifest ab. Der Angreifer setzt beides stimmig.
attack privilegiert       '.spec.containers[0].securityContext.privileged = true | .spec.containers[0].securityContext.allowPrivilegeEscalation = true'
attack als-root           '.spec.containers[0].securityContext.runAsNonRoot = false | .spec.containers[0].securityContext.runAsUser = 0'
attack rechteausweitung   '.spec.containers[0].securityContext.allowPrivilegeEscalation = true'
attack host-netzwerk      '.spec.hostNetwork = true'
