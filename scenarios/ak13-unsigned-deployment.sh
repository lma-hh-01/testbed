#!/usr/bin/env bash
# AK-13: Deployment of malicious container images in Kubernetes.
# An attacker with the permissions of the deployer brings a foreign image into
# the cluster that was not built and signed by the pipeline. They try several
# ways: directly as a pod, via a Deployment, Job and CronJob, and in another
# namespace.
source "$(dirname "$0")/lib.sh"

AK="AK-13"
# Stands for any foreign image. It runs harmlessly, all that matters is that
# the signature of the pipeline is missing.
FOREIGN_IMAGE="$ALPINE_IMAGE"

describe "$AK" "Deploy an unsigned image" \
  "With the permissions of the deployer a foreign image is brought into the cluster in several ways, including into another namespace."

attack() {
  local case="$1"
  local kind="$2"
  local namespace="${3:-$APP_NAMESPACE}"
  local manifest="$SCENARIO_DIR/ak13-$case.yaml"

  step "Case '$case': $kind with a foreign image in namespace $namespace"
  workload_manifest "$kind" "ak13-$case" "$FOREIGN_IMAGE" "$namespace" > "$manifest"
  try_apply "$manifest"
  record_result "$AK" "$case" "$RESULT" "$DETAIL" "$FOREIGN_IMAGE"
  remove_manifest "$manifest"
}

# The last case tries another namespace, in which the deployer has no
# permissions in any variant.
attack pod pod
attack deployment deployment
attack job job
attack cronjob cronjob
attack other-namespace pod default
