#!/usr/bin/env bash
# AK-12: Manipulation der Verifikationsprozesse.
# Ein Angreifer mit den Rechten des Deployers versucht, die Pruefung an der
# Admission auszuhebeln: die Richtlinien aendern, eine Ausnahme anlegen, den
# Webhook entfernen, Kyverno selbst veraendern oder sich ueber eine zusaetzliche
# Rollenbindung mehr Rechte verschaffen. Der Schutz (AF-14) beruht auf der
# Rechtevergabe im Cluster, die in allen Varianten gleich eingeschraenkt ist.
source "$(dirname "$0")/lib.sh"

AK="AK-12"
HYPOTHESIS=alle

describe "$AK" "Verifikation manipulieren" \
  "Der Deployer versucht, die Verifikation an der Admission zu veraendern. Geprueft wird, ob seine Rechte das zulassen. Erwartet: in allen Varianten verweigert, weil der Deployer nur Anwendungsressourcen in seinem Namespace verwalten darf. Ab V1 existieren die Zielobjekte tatsaechlich, der Schutz ist aber in jeder Variante gleich."

attack() {
  local case="$1"
  local verb="$2"
  local resource="$3"
  local namespace="$4"

  step "Fall '$case': $verb $resource${namespace:+ (Namespace $namespace)}"
  try_permission "$verb" "$resource" "$namespace"
  record_result "$AK" "$case" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$resource"
}

attack richtlinie-aendern  delete imagevalidatingpolicies.policies.kyverno.io  ""
attack ausnahme-anlegen    create policyexceptions.policies.kyverno.io          "$APP_NAMESPACE"
attack webhook-entfernen   delete validatingwebhookconfigurations.admissionregistration.k8s.io ""
attack kyverno-aendern     patch  deployments.apps                             "kyverno"
attack rechte-ausweiten    create rolebindings.rbac.authorization.k8s.io        "$APP_NAMESPACE"
