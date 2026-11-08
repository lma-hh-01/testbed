#!/usr/bin/env bash
# AK-13: Deployment boesartiger Container-Images in Kubernetes.
# Ein Angreifer mit den Rechten des Deployers bringt ein fremdes Image in den
# Cluster, das nicht von der Pipeline gebaut und signiert wurde. Er versucht
# verschiedene Wege: direkt als Pod, ueber Deployment, Job und CronJob und in
# einem anderen Namespace.
source "$(dirname "$0")/lib.sh"

AK="AK-13"
# Steht fuer ein beliebiges fremdes Image. Es laeuft harmlos, entscheidend ist
# nur, dass die Signatur der Pipeline fehlt.
FOREIGN_IMAGE="$ALPINE_IMAGE"

describe "$AK" "Unsigniertes Image deployen" \
  "Mit den Rechten des Deployers wird ein fremdes Image auf mehreren Wegen in den Cluster gebracht. Erwartet: In V0 laeuft es, ab V1 lehnt Kyverno jeden Weg ab, weil die Signatur der Pipeline fehlt. In einen anderen Namespace darf der Deployer in keiner Variante."

attack() {
  local case="$1"
  local hypothesis="$2"
  local kind="$3"
  local namespace="${4:-$APP_NAMESPACE}"
  local manifest="$SCENARIO_DIR/ak13-$case.yaml"

  step "Fall '$case': $kind mit fremdem Image im Namespace $namespace"
  workload_manifest "$kind" "ak13-$case" "$FOREIGN_IMAGE" "$namespace" > "$manifest"
  try_apply "$manifest"
  record_result "$AK" "$case" "$hypothesis" "$RESULT" "$DETAIL" "$FOREIGN_IMAGE"
  remove_manifest "$manifest"
}

# Hypothese je Fall: ab V1 die Signaturpruefung. Den anderen Namespace verhindert
# die Rechtevergabe des Deployers, die in allen Varianten gleich ist.
attack pod V1 pod
attack deployment V1 deployment
attack job V1 job
attack cronjob V1 cronjob
attack anderer-namespace alle pod default
