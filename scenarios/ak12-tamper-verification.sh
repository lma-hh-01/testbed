#!/usr/bin/env bash
# AK-12: Manipulation of the verification processes.
# An attacker with the permissions of the deployer tries to undermine the
# verification at admission: change the policies, create an exception, remove
# the webhook, change Kyverno itself or gain more permissions via an additional
# role binding. The protection (AF-14) relies on the permission assignment in
# the cluster, which is restricted in the same way in all variants.
source "$(dirname "$0")/lib.sh"

AK="AK-12"
HYPOTHESIS=all

describe "$AK" "Tamper with the verification" \
  "The deployer tries to change the verification at admission. Checked is whether its permissions allow that. Expected: denied in all variants, because the deployer may only manage application resources in its namespace. From V1 on the target objects actually exist, but the protection is the same in every variant."

attack() {
  local case="$1"
  local verb="$2"
  local resource="$3"
  local namespace="$4"

  step "Case '$case': $verb $resource${namespace:+ (namespace $namespace)}"
  try_permission "$verb" "$resource" "$namespace"
  record_result "$AK" "$case" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$resource"
}

attack change-policy         delete imagevalidatingpolicies.policies.kyverno.io  ""
attack create-exception      create policyexceptions.policies.kyverno.io          "$APP_NAMESPACE"
attack remove-webhook        delete validatingwebhookconfigurations.admissionregistration.k8s.io ""
attack change-kyverno        patch  deployments.apps                             "kyverno"
attack escalate-privileges   create rolebindings.rbac.authorization.k8s.io        "$APP_NAMESPACE"
