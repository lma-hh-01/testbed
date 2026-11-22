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

# --- Lokaler Build -------------------------------------------------------------

# Szenarien, die ein Image ausserhalb der Pipeline bauen, nutzen einen eigenen
# BuildKit-Builder. Der Standard-Treiber von Docker kann kein OCI-Layout ausgeben.
LOCAL_BUILDER="testbed"

# Baut example-app fuer linux/amd64 als OCI-Layout in das angegebene Verzeichnis.
# Weitere Argumente gehen an "docker buildx build", z. B. --build-arg.
local_build() {
  local layout="$1"
  shift
  docker buildx inspect "$LOCAL_BUILDER" >/dev/null 2>&1 ||
    docker buildx create --name "$LOCAL_BUILDER" --driver docker-container \
      --driver-opt "image=$BUILDKIT_IMAGE" >/dev/null
  rm -rf "$layout" "$layout.tar"
  docker buildx build --builder "$LOCAL_BUILDER" --quiet --platform linux/amd64 \
    --provenance=false --sbom=false "$@" \
    --output "type=oci,dest=$layout.tar" "$EXAMPLE_APP_DIR" >/dev/null
  mkdir -p "$layout"
  tar -xf "$layout.tar" -C "$layout"
}

# --- Legitimes Pipeline-Image --------------------------------------------------

# Holt das von der Pipeline gebaute (und ab V1 signierte) Image der aktuellen
# Variante nach zot, wie es deploy.sh tut, und gibt die Referenz im Cluster aus.
# Nutzen Szenarien, bei denen ein Angriff an einem legitimen Image ansetzt, damit
# eine Ablehnung nur am untersuchten Merkmal liegt und nicht an der Signatur.
pipeline_image_in_zot() {
  local image="ghcr.io/$GITHUB_OWNER/example-app-$VARIANT"
  local url="https://api.github.com/repos/$GITHUB_OWNER/example-app/actions/workflows/$VARIANT.yml/runs?branch=main&status=success&per_page=1"
  local commit tag digest
  commit="$(curl -fsSL "$url" | jq -r '.workflow_runs[0].head_sha // empty')"
  [ -n "$commit" ] || fail "Kein erfolgreicher Lauf von $VARIANT.yml auf main gefunden."
  tag="$commit"
  [ "$VARIANT" = v0 ] && tag=latest
  digest="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$image:$tag")"
  oras cp --recursive --from-registry-config "$ORAS_AUTH_FILE" --to-registry-config "$ORAS_AUTH_FILE" \
    "$image@$digest" "$ZOT_HOST_ADDRESS/example-app-$VARIANT:$tag" >/dev/null
  echo "$ZOT_CLUSTER_ADDRESS/example-app-$VARIANT@$digest"
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

# Prueft als Deployer, ob eine Aktion erlaubt ist (kubectl auth can-i). Fuer
# Angriffe, die an der Rechtevergabe scheitern sollen, unabhaengig davon, ob das
# Zielobjekt in der Variante existiert. Ein leerer Namespace prueft clusterweit
# bzw. im Namespace des Deployers. Setzt RESULT und DETAIL.
# shellcheck disable=SC2034 # beide lesen die Szenario-Skripte
try_permission() {
  local verb="$1"
  local resource="$2"
  local namespace="$3"
  local args=(auth can-i "$verb" "$resource")
  [ -n "$namespace" ] && args+=(--namespace "$namespace")
  if deployer_kubectl "${args[@]}" >/dev/null 2>&1; then
    RESULT=durchgelassen
    DETAIL="Deployer darf $verb $resource"
  else
    RESULT=rbac-verweigert
    DETAIL="Deployer darf $verb $resource nicht"
  fi
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

# =============================================================================
# Helfer fuer die Szenarien, die echt ueber GitHub angreifen (AK-02/03, 05, 06,
# 10a, 11). Ein Push auf main baut alle vier Varianten gleichzeitig, der lokale
# Cluster laeuft aber nur mit einer Variante. Deshalb greift das erste
# "make scenario" einmal echt an, haelt das Build-Ergebnis und den zu deployenden
# Commit je Variante fest, stellt sofort wieder her und wertet dann die laufende
# Variante aus. Jeder weitere Aufruf (andere Variante) liest nur den Zustand und
# wertet gegen seinen Cluster aus. Der Zustand liegt unter results/ und ueberlebt
# "make down". Mit ANGRIFF=neu wird erneut angegriffen.
# =============================================================================

EXAMPLE_APP_REPO="$GITHUB_OWNER/example-app"
# shellcheck disable=SC2034 # lesen die Szenario-Skripte (AK-06 Fall 2, AK-02/03)
SECURE_WORKFLOWS_REPO="$GITHUB_OWNER/secure-workflows"
STATE_DIR="$TESTBED_DIR/results/state"

# --- Voraussetzungen ----------------------------------------------------------

# Prueft, dass die GitHub CLI angemeldet und der aktive Account der erwartete ist.
github_scenario_guard() {
  command -v gh >/dev/null || fail "Dieses Szenario braucht die GitHub CLI 'gh'."
  gh auth status --active >/dev/null 2>&1 || fail "gh ist nicht angemeldet. Erst 'gh auth login' ausfuehren."
  local active
  active="$(gh api user --jq .login 2>/dev/null || true)"
  [ "$active" = "$GITHUB_OWNER" ] ||
    fail "Aktiver gh-Account ist '${active:-unbekannt}', erwartet '$GITHUB_OWNER'. Mit 'gh auth switch' wechseln."
}

# --- Laeufe starten und abwarten ----------------------------------------------

# Wartet, bis ein Lauf abgeschlossen ist, und gibt dessen Ergebnis (conclusion) aus.
wait_for_run() {
  local repo="$1" run_id="$2"
  until [ "$(gh run view "$run_id" --repo "$repo" --json status --jq .status)" = completed ]; do
    sleep 10
  done
  gh run view "$run_id" --repo "$repo" --json conclusion --jq .conclusion
}

# Liest Ergebnis, Commit und fehlgeschlagene Schritte eines Laufs in Variablen.
# shellcheck disable=SC2034 # RUN_* lesen die Szenario-Skripte
fill_run_outputs() {
  local repo="$1" run_id="$2"
  RUN_CONCLUSION="$(wait_for_run "$repo" "$run_id")"
  RUN_HEAD_SHA="$(gh run view "$run_id" --repo "$repo" --json headSha --jq .headSha)"
  RUN_FAILED_STEPS="$(gh run view "$run_id" --repo "$repo" --json jobs \
    --jq '[.jobs[].steps[] | select(.conclusion == "failure") | .name] | join("; ")')"
}

# Startet einen Workflow-Lauf von Hand (workflow_dispatch) auf einem Branch und
# wartet auf sein Ende. Setzt RUN_ID, RUN_CONCLUSION, RUN_HEAD_SHA, RUN_FAILED_STEPS.
dispatch_and_wait() {
  local variant="$1" ref="$2"
  local repo="$EXAMPLE_APP_REPO" workflow="$1.yml"
  local before
  before="$(gh run list --repo "$repo" --workflow "$workflow" --branch "$ref" -L 1 --json databaseId --jq '.[0].databaseId // 0')"
  gh workflow run "$workflow" --repo "$repo" --ref "$ref" >/dev/null
  RUN_ID="$before"
  until [ -n "$RUN_ID" ] && [ "$RUN_ID" != "$before" ]; do
    sleep 5
    RUN_ID="$(gh run list --repo "$repo" --workflow "$workflow" --branch "$ref" -L 1 --json databaseId --jq '.[0].databaseId // 0')"
  done
  fill_run_outputs "$repo" "$RUN_ID"
}

# Wartet auf den durch einen Push ausgeloesten Lauf einer Variante fuer einen
# bestimmten Commit. Setzt dieselben Variablen wie dispatch_and_wait.
wait_for_push_run() {
  local variant="$1" commit="$2"
  local repo="$EXAMPLE_APP_REPO"
  RUN_ID=""
  until [ -n "$RUN_ID" ]; do
    sleep 5
    RUN_ID="$(gh run list --repo "$repo" --workflow "$variant.yml" --commit "$commit" -L 1 --json databaseId --jq '.[0].databaseId // empty')"
  done
  fill_run_outputs "$repo" "$RUN_ID"
}

# --- Deployment eines bestimmten Commits --------------------------------------

# Rendert das regulaere Deployment-Manifest eines Commits mit gesetzter
# Image-Referenz (wie scripts/deploy.sh, aber fuer einen frei waehlbaren Commit).
render_app_deployment() {
  local commit="$1" image="$2"
  git -C "$EXAMPLE_APP_DIR" show "$commit:k8s/deployment.yaml" | IMAGE="$image" yq '
    (.spec.template.spec.containers[0].image = strenv(IMAGE)) |
    (.spec.template.spec.containers[0].env[] | select(.name == "DEPLOYED_IMAGE") | .value) = strenv(IMAGE)
  '
}

# Kopiert das von der Pipeline gebaute Image eines bestimmten Commits nach zot und
# gibt die Cluster-Referenz aus. Anders als pipeline_image_in_zot ist der Commit
# frei waehlbar, damit das aus einem Angriffslauf entstandene Image gezielt gegen
# die Admission gefuehrt werden kann. V0 ueber einen Tag (kein Digest).
# shellcheck disable=SC2034 # DEPLOY_IMAGE liest das Szenario-Skript
deploy_commit_to_cluster() {
  local variant="$1" commit="$2" tag="${3:-$2}"
  local ghcr="ghcr.io/$GITHUB_OWNER/example-app-$variant" zot_repo="example-app-$variant"
  local digest
  digest="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$ghcr:$tag")"
  oras cp --recursive --from-registry-config "$ORAS_AUTH_FILE" --to-registry-config "$ORAS_AUTH_FILE" \
    "$ghcr@$digest" "$ZOT_HOST_ADDRESS/$zot_repo:$tag" >/dev/null
  if [ "$variant" = v0 ]; then
    DEPLOY_IMAGE="$ZOT_CLUSTER_ADDRESS/$zot_repo:$tag"
  else
    DEPLOY_IMAGE="$ZOT_CLUSTER_ADDRESS/$zot_repo@$digest"
  fi
}

# Wertet den festgehaltenen Angriff gegen die laufende Variante aus: ist kein
# Image entstanden, gilt der Angriff als in der Pipeline gescheitert; sonst wird
# das Image dieses Commits deployt und an der Admission geprueft.
evaluate_from_state() {
  local ak="$1" case="$2" hypothesis="$3" state_name="$4"
  load_variant_state "$state_name"

  if [ "$SV_RESULT" = build-abgebrochen ]; then
    RESULT=build-abgebrochen
    record_result "$ak" "$case" "$hypothesis" "$RESULT" "$SV_NOTE" "kein Image gebaut"
    return
  fi

  step "Image des Angriffs (Commit ${SV_DEPLOY:0:7}) als Deployer deployen"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin >/dev/null 2>&1 || true
  deploy_commit_to_cluster "$VARIANT" "$SV_DEPLOY" "$SV_TAG"
  info "Image im Cluster: $DEPLOY_IMAGE"
  local manifest="$SCENARIO_DIR/$case.yaml"
  render_app_deployment "$SV_DEPLOY" "$DEPLOY_IMAGE" > "$manifest"
  try_apply "$manifest"
  record_result "$ak" "$case" "$hypothesis" "$RESULT" "$DETAIL" "$DEPLOY_IMAGE"
  remove_manifest "$manifest"
}

# --- Zustand des einmaligen Angriffs ------------------------------------------

STATE_FILE=""

# Legt eine frische Zustandsdatei fuer ein Szenario an.
init_attack_state() {
  STATE_FILE="$STATE_DIR/$1.env"
  mkdir -p "$STATE_DIR"
  : > "$STATE_FILE"
}

# Haelt fuer eine Variante fest, was der Angriff ergeben hat: das Build-Ergebnis
# (gebaut oder build-abgebrochen), den zu deployenden Commit samt Tag und eine Notiz.
set_variant_state() {
  local v="$1"
  printf 'STATE_%s_RESULT=%q\nSTATE_%s_DEPLOY=%q\nSTATE_%s_TAG=%q\nSTATE_%s_NOTE=%q\n' \
    "$v" "$2" "$v" "$3" "$v" "$4" "$v" "$5" >> "$STATE_FILE"
}

# Wahr, wenn fuer dieses Szenario schon ein Angriff gelaufen ist (ausser ANGRIFF=neu).
attack_done() {
  [ -f "$STATE_DIR/$1.env" ] && [ "${ANGRIFF:-}" != neu ]
}

# Liest den Zustand der laufenden Variante in SV_RESULT, SV_DEPLOY, SV_TAG, SV_NOTE.
load_variant_state() {
  # shellcheck source=/dev/null
  source "$STATE_DIR/$1.env"
  eval "SV_RESULT=\${STATE_${VARIANT}_RESULT:-}"
  eval "SV_DEPLOY=\${STATE_${VARIANT}_DEPLOY:-}"
  eval "SV_TAG=\${STATE_${VARIANT}_TAG:-}"
  eval "SV_NOTE=\${STATE_${VARIANT}_NOTE:-}"
}

# --- Pull Requests und Wiederherstellung --------------------------------------

# Legt einen Branch mit den bereits committeten Aenderungen als PR an, merged ihn
# als Merge-Commit und holt main nach. Gibt den Merge-Commit aus (MERGE_COMMIT).
# shellcheck disable=SC2034 # MERGE_COMMIT liest das Szenario-Skript
open_and_merge_pr() {
  local repo="$1" branch="$2" title="$3" dir="$4"
  git -C "$dir" push --quiet origin "$branch"
  gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body "$title" >/dev/null
  gh pr merge "$branch" --repo "$repo" --merge --delete-branch >/dev/null
  git -C "$dir" switch --quiet main
  git -C "$dir" pull --quiet --ff-only origin main
  MERGE_COMMIT="$(git -C "$dir" rev-parse HEAD)"
}

# =============================================================================
# Treiber fuer die Szenarien, die den Angriff ueber einen signierten Commit auf
# example-app/main einbringen (AK-05 Fall b, AK-06 Fall 1, AK-10a, AK-11).
# gitsign braucht einen Browser-Login, den Claude nicht selbst ausfuehren kann.
# Der Treiber bereitet die Aenderung vor und nennt den exakten Commit-Befehl fuer
# Lukas; nach dem Signieren startet derselbe Aufruf den PR, wertet die Builds aus
# und stellt per Revert wieder her (ebenfalls ein signierter Commit). Der Zustand
# steht in results/state/<ak>.phase, sodass "make scenario" mehrfach denselben
# Ablauf fortsetzt.
# =============================================================================

# Gibt den exakten Befehl aus, den Lukas ausfuehren muss, und wie es weitergeht.
print_sign_prompt() {
  local branch="$1" title="$2" ak="$3"
  step "Signatur von Lukas noetig"
  info "Die Aenderung liegt bereit auf Branch '$branch' (noch nicht committet)."
  info "Bitte signiert committen (oeffnet den Browser-Login von gitsign):"
  printf '\n    ! git -C %s commit -m "%s"\n\n' "$EXAMPLE_APP_DIR" "$title"
  info "Danach erneut ausfuehren: make scenario AK=${ak}"
}

# Wahr, wenn auf dem Branch ein signierter Commit vor origin/main liegt.
has_signed_commit() {
  local branch="$1"
  git -C "$EXAMPLE_APP_DIR" rev-parse --quiet --verify "$branch" >/dev/null || return 1
  [ "$(git -C "$EXAMPLE_APP_DIR" rev-list --count "origin/main..$branch")" -ge 1 ] || return 1
  git -C "$EXAMPLE_APP_DIR" cat-file commit "$branch" | grep '^gpgsig' >/dev/null
}

# Legt den Angriffs-Branch an und laesst die Vorbereitungsfunktion die Dateien
# aendern. Committet wird nicht (das macht Lukas signiert).
prepare_attack_branch() {
  local branch="$1" prepare_fn="$2"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  git -C "$EXAMPLE_APP_DIR" switch --quiet -C "$branch" origin/main
  "$prepare_fn"
  git -C "$EXAMPLE_APP_DIR" add -A
}

# Legt den Revert-Branch an und bereitet die Ruecknahme des Merge-Commits vor.
prepare_revert_branch() {
  local branch="$1" merge="$2"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  git -C "$EXAMPLE_APP_DIR" switch --quiet -C "$branch" origin/main
  git -C "$EXAMPLE_APP_DIR" revert --no-commit -m 1 "$merge"
}

# Wartet je Variante auf den durch den Merge ausgeloesten Push-Lauf und haelt fest,
# wie der Angriff auszuwerten ist. Entscheidend ist nicht das Lauf-Ergebnis,
# sondern ob ein Image in ghcr liegt: Ein spaet scheiternder Schritt (z. B. das
# Schwachstellen-Gate in V3) laesst ein unsigniertes Image zurueck, das dann an
# der Admission zu pruefen ist. Bricht der Build vor dem Push ab (z. B. die
# Commit-Pruefung), entsteht kein Image und der Angriff gilt als abgewehrt.
record_push_builds() {
  local state_name="$1" merge="$2" variant image
  init_attack_state "$state_name"
  for variant in v0 v1 v2 v3; do
    step "Auf Push-Lauf von $variant.yml fuer ${merge:0:7} warten"
    wait_for_push_run "$variant" "$merge"
    info "Lauf $RUN_ID: $RUN_CONCLUSION"
    image="ghcr.io/$GITHUB_OWNER/example-app-$variant"
    if oras resolve --registry-config "$ORAS_AUTH_FILE" "$image:$merge" >/dev/null 2>&1; then
      set_variant_state "$variant" gebaut "$merge" "$merge" "Build $RUN_CONCLUSION, Image in ghcr"
    else
      set_variant_state "$variant" build-abgebrochen "" "" "Schritt: ${RUN_FAILED_STEPS:-vor dem Push abgebrochen}"
    fi
  done
}

# Prueft, dass nach dem Revert wieder alle Varianten gruen bauen (Pipeline nutzbar).
verify_restore_green() {
  local merge="$1" variant
  for variant in v1 v2 v3; do
    step "Wiederherstellung pruefen: $variant.yml fuer ${merge:0:7}"
    wait_for_push_run "$variant" "$merge"
    [ "$RUN_CONCLUSION" = success ] ||
      fail "Nach dem Revert scheitert $variant.yml (Lauf $RUN_ID). main ist noch blockiert."
    info "Lauf $RUN_ID: success"
  done
}

# Der eigentliche Zustandsautomat. EVALUATE_FN wertet eine Variante aus dem
# gespeicherten Zustand aus (siehe evaluate_from_state oder szenariospezifisch).
run_signed_app_scenario() {
  local state_name="$1" branch="$2" title="$3" prepare_fn="$4" evaluate_fn="$5"
  local phase_file="$STATE_DIR/$state_name.phase"
  mkdir -p "$STATE_DIR"

  local PHASE=fresh
  # shellcheck source=/dev/null
  [ -f "$phase_file" ] && source "$phase_file"
  [ "${ANGRIFF:-}" = neu ] && PHASE=fresh

  if [ "$PHASE" = fresh ]; then
    step "Angriff vorbereiten: $title"
    prepare_attack_branch "$branch" "$prepare_fn"
    printf 'PHASE=attack-prepared\n' > "$phase_file"
    print_sign_prompt "$branch" "$title" "$AK_FLAG"
    exit 0
  fi

  if [ "$PHASE" = attack-prepared ]; then
    if ! has_signed_commit "$branch"; then
      print_sign_prompt "$branch" "$title" "$AK_FLAG"
      exit 0
    fi
    step "Angriff auf main bringen (PR + Merge)"
    open_and_merge_pr "$EXAMPLE_APP_REPO" "$branch" "$title" "$EXAMPLE_APP_DIR"
    record_push_builds "$state_name" "$MERGE_COMMIT"
    step "Wiederherstellung vorbereiten (Revert)"
    prepare_revert_branch "$branch-revert" "$MERGE_COMMIT"
    printf 'PHASE=restore-prepared\n' > "$phase_file"
    print_sign_prompt "$branch-revert" "Revert: $title" "$AK_FLAG"
    exit 0
  fi

  if [ "$PHASE" = restore-prepared ]; then
    if ! has_signed_commit "$branch-revert"; then
      print_sign_prompt "$branch-revert" "Revert: $title" "$AK_FLAG"
      exit 0
    fi
    step "Wiederherstellung auf main bringen (Revert-PR + Merge)"
    open_and_merge_pr "$EXAMPLE_APP_REPO" "$branch-revert" "Revert: $title" "$EXAMPLE_APP_DIR"
    verify_restore_green "$MERGE_COMMIT"
    printf 'PHASE=done\n' > "$phase_file"
  fi

  # PHASE=done: nur noch auswerten (auch bei weiteren Varianten)
  "$evaluate_fn"
}
