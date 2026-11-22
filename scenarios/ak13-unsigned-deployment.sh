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
  "With the permissions of the deployer a foreign image is brought into the cluster in several ways. Expected: in V0 it runs, from V1 on Kyverno denies every way, because the signature of the pipeline is missing. The deployer may not deploy into another namespace in any variant."

attack() {
  local case="$1"
  local hypothesis="$2"
  local kind="$3"
  local namespace="${4:-$APP_NAMESPACE}"
  local manifest="$SCENARIO_DIR/ak13-$case.yaml"

  step "Case '$case': $kind with a foreign image in namespace $namespace"
  workload_manifest "$kind" "ak13-$case" "$FOREIGN_IMAGE" "$namespace" > "$manifest"
  try_apply "$manifest"
  record_result "$AK" "$case" "$hypothesis" "$RESULT" "$DETAIL" "$FOREIGN_IMAGE"
  remove_manifest "$manifest"
}

# Hypothesis per case: from V1 on the signature verification. The other
# namespace is prevented by the permission assignment of the deployer, which is
# the same in all variants.
attack pod V1 pod
attack deployment V1 deployment
attack job V1 job
attack cronjob V1 cronjob
attack other-namespace all pod default
