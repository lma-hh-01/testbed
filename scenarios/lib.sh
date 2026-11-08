#!/usr/bin/env bash
# Gemeinsame Hilfsfunktionen fuer die Angriffsszenarien.
# Wird von den Szenario-Skripten mit "source" eingebunden.
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

[ -f "$WORK_DIR/variant" ] || fail "Kein Testbed gefunden. Erst 'make cluster VARIANT=...' ausfuehren."
VARIANT="$(cat "$WORK_DIR/variant")"

SCENARIO_DIR="$WORK_DIR/scenarios"
mkdir -p "$SCENARIO_DIR"
RESULTS_FILE="${RESULTS_FILE:-$WORK_DIR/szenarien.csv}"
mkdir -p "$(dirname "$RESULTS_FILE")"
RESULTS_HEADER="zeitpunkt,variante,ak,fall,hypothese,ergebnis,wie_erwartet,detail,artefakt,stand"

# --- Ausgabe ------------------------------------------------------------------

describe() {
  local ak="$1"
  local title="$2"
  local text="$3"
  printf '\n### %s: %s (Variante %s)\n' "$ak" "$title" "$VARIANT"
  printf '%s\n' "$text" | fold -s -w 76 | sed 's/^/    /'
}

# --- Manifeste ----------------------------------------------------------------

# Erzeugt ein Manifest fuer Pod, Deployment, Job oder CronJob. Die Container
# erfuellen die Pod-Sicherheitsrichtlinie von V3, damit eine Ablehnung nur am
# untersuchten Merkmal liegen kann und nicht an der Sicherheitskonfiguration.
workload_manifest() {
  local kind="$1"
  local name="$2"
  local image="$3"
  local namespace="${4:-$APP_NAMESPACE}"
  local create
  case "$kind" in
    pod) create=(run "$name" --image "$image" --restart Never) ;;
    deployment) create=(create deployment "$name" --image "$image") ;;
    job) create=(create job "$name" --image "$image") ;;
    cronjob) create=(create cronjob "$name" --image "$image" --schedule '*/30 * * * *') ;;
    *) fail "Unbekannte Art von Workload: $kind" ;;
  esac
  deployer_kubectl "${create[@]}" --dry-run=client -o yaml -- sleep 3600 | NAMESPACE="$namespace" yq '
    .metadata.namespace = strenv(NAMESPACE) |
    (.. | select(tag == "!!map" and has("containers")) | .containers[].securityContext) = {
      "runAsNonRoot": true,
      "runAsUser": 10001,
      "allowPrivilegeEscalation": false,
      "capabilities": {"drop": ["ALL"]}
    }'
}

# --- Angriff ausfuehren und einordnen -----------------------------------------

# Wendet ein Manifest mit den Rechten des Deployers an und ordnet das Ergebnis ein.
# Setzt RESULT (durchgelassen, admission-abgelehnt oder rbac-verweigert) und DETAIL.
# shellcheck disable=SC2034 # beide lesen die Szenario-Skripte
try_apply() {
  local manifest="$1"
  local output
  if output="$(deployer_kubectl apply -f "$manifest" 2>&1)"; then
    RESULT=durchgelassen
    DETAIL=""
  elif grep -q 'admission webhook' <<<"$output"; then
    RESULT=admission-abgelehnt
    DETAIL="$(sed -n 's/.*failed: //p' <<<"$output" | head -n 1)"
  elif grep -q 'cannot [a-z]* resource' <<<"$output"; then
    RESULT=rbac-verweigert
    DETAIL="$(sed -n 's/.*forbidden: //p' <<<"$output" | head -n 1)"
  else
    fail "Unerwartete Antwort des Clusters: $output"
  fi
}

remove_manifest() {
  deployer_kubectl delete -f "$1" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# --- Ergebnisse ---------------------------------------------------------------

# Die Hypothese aus Kap. 5 nennt die Variante, ab der ein Angriff abgewehrt wird
# (z. B. V1), oder "alle", wenn er in jeder Variante abgewehrt werden soll.
defense_expected() {
  local hypothesis="$1"
  [ "$hypothesis" = alle ] && return 0
  [ "${VARIANT#v}" -ge "${hypothesis#V}" ]
}

csv_field() {
  local value="${1//$'\n'/ }"
  printf '"%s"' "${value//\"/\"\"}"
}

repo_state() {
  local repo state=()
  for repo in testbed secure-workflows example-app; do
    state+=("$repo@$(git -C "$TESTBED_DIR/../$repo" rev-parse --short HEAD)")
  done
  echo "${state[*]}"
}

record_result() {
  local ak="$1"
  local case="$2"
  local hypothesis="$3"
  local result="$4"
  local detail="$5"
  local artifact="$6"

  local defended=nein expected=nein as_expected=nein
  [ "$result" != durchgelassen ] && defended=ja
  defense_expected "$hypothesis" && expected=ja
  [ "$defended" = "$expected" ] && as_expected=ja

  [ -f "$RESULTS_FILE" ] || echo "$RESULTS_HEADER" > "$RESULTS_FILE"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$VARIANT" "$ak" "$case" "$hypothesis" "$result" \
    "$as_expected" "$(csv_field "$detail")" "$(csv_field "$artifact")" "$(csv_field "$(repo_state)")" \
    >> "$RESULTS_FILE"

  info "Ergebnis: $result${detail:+ ($detail)}"
  local hypothesis_text="abgewehrt ab $hypothesis"
  [ "$hypothesis" = alle ] && hypothesis_text="abgewehrt in allen Varianten"
  if [ "$as_expected" = ja ]; then
    info "Wie erwartet (Hypothese: $hypothesis_text)."
  else
    info "ABWEICHUNG von der Hypothese ($hypothesis_text)."
  fi
}
