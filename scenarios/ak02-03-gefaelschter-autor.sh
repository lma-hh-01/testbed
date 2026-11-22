#!/usr/bin/env bash
# AK-02/03: Commit mit gefaelschtem Autor.
# Zwei Faelle, beide als echter Angriff auf example-app/main:
#   gefaelschter-autor (Hyp V1): Ein Commit mit gefaelschter Autor-Angabe und ohne
#     gueltige Signatur wird gemergt. Die Commit-Pruefung im Workflow bricht ab,
#     es entsteht kein Image -> ab V1 abgewehrt.
#   pruefung-entfernt (Hyp V2): Im selben Zug entfernt der Angreifer die
#     Commit-Pruefung aus dem App-Workflow (nur in V1 moeglich). V1 baut und
#     signiert dann trotzdem -> nicht abgewehrt. V2/V3 pruefen im zentralen
#     Workflow weiter -> ab V2 abgewehrt.
#
# WARNUNG: Dieses Szenario veraendert die Vertrauensbasis dauerhaft. Die
# gefaelschten Commits bleiben in der Historie, V1-V3 scheitern danach, bis der
# Vertrauensanker vorgeschoben ist. Die Wiederherstellung verschiebt den Anker in
# secure-workflows (v2/v3, normaler PR) und in example-app (v1, signierter Commit
# von Lukas) auf den Angriffs-Merge und stellt den Code auf den Stand davor zurueck.
# Nur mit bereitem Anker-Restore ausfuehren. Der Angriff selbst ist unsigniert und
# wird ohne Lukas erzeugt; nur die Wiederherstellung braucht eine Signatur.
source "$(dirname "$0")/lib.sh"

AK="AK-02/03"
# shellcheck disable=SC2034 # AK_FLAG liest der Treiber/print_sign_prompt in lib.sh
AK_FLAG="02-03"
FORGED_AUTHOR="AK0203 Faelscher <faelscher@angreifer.invalid>"
ANCHOR_BRANCH_APP="ak0203-anker-example-app"

describe "$AK" "Commit mit gefaelschtem Autor" \
  "Ein Commit mit gefaelschter Autor-Angabe wird nach main gemergt (gefaelschter-autor), im zweiten Fall zusaetzlich mit entfernter Commit-Pruefung im App-Workflow (pruefung-entfernt). Erwartet: gefaelschter-autor ab V1 abgewehrt (Build bricht ab), pruefung-entfernt erst ab V2 (die Pruefung liegt dann im zentralen Workflow)."

github_scenario_guard

# --- Angriffe ----------------------------------------------------------------

# Modifiziert app/main.py, damit der gefaelschte Commit eine Aenderung traegt.
forge_harmless_change() {
  printf '\n# AK-02/03: Aenderung eines nicht autorisierten Autors\n' \
    >> "$EXAMPLE_APP_DIR/app/main.py"
}

# Entfernt zusaetzlich die Commit-Pruefung aus dem App-Workflow v1.yml.
forge_and_remove_check() {
  forge_harmless_change
  local wf="$EXAMPLE_APP_DIR/.github/workflows/v1.yml"
  yq 'del(.jobs.build.steps[] | select(.name == "Commit-Signaturen pruefen"))' "$wf" > "$wf.tmp"
  mv "$wf.tmp" "$wf"
}

# Legt einen Branch mit einem gefaelschten, unsignierten Commit an und merged ihn
# per PR nach main. Setzt MERGE_COMMIT.
forged_merge() {
  local branch="$1" title="$2" modify_fn="$3"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  git -C "$EXAMPLE_APP_DIR" switch --quiet -C "$branch" origin/main
  "$modify_fn"
  git -C "$EXAMPLE_APP_DIR" add -A
  git -C "$EXAMPLE_APP_DIR" -c commit.gpgsign=false commit --quiet \
    --author="$FORGED_AUTHOR" -m "$title"
  open_and_merge_pr "$EXAMPLE_APP_REPO" "$branch" "$title" "$EXAMPLE_APP_DIR"
}

# --- Wiederherstellung (Anker verschieben) -----------------------------------

# Setzt den Vertrauensanker in einer Workflow-Datei auf den angegebenen Commit.
set_anchor() {
  local file="$1" anchor="$2"
  sed "s/\(TRUST_ANCHOR: \).*/\1$anchor/" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# Verschiebt den Anker in secure-workflows (v2, v3) per normalem PR (keine Signatur).
move_platform_anchor() {
  local anchor="$1" branch="ak0203-anker-plattform" f
  git -C "$SECURE_WORKFLOWS_DIR" fetch --quiet origin main
  git -C "$SECURE_WORKFLOWS_DIR" switch --quiet -C "$branch" origin/main
  for f in v2 v3; do
    set_anchor "$SECURE_WORKFLOWS_DIR/.github/workflows/$f.yml" "$anchor"
  done
  git -C "$SECURE_WORKFLOWS_DIR" add -A
  git -C "$SECURE_WORKFLOWS_DIR" -c commit.gpgsign=false commit --quiet \
    -m "AK-02/03 Wiederherstellung: Vertrauensanker verschieben"
  open_and_merge_pr "$SECURE_WORKFLOWS_REPO" "$branch" \
    "AK-02/03 Wiederherstellung: Vertrauensanker verschieben" "$SECURE_WORKFLOWS_DIR"
}

# Bereitet den Anker-Commit in example-app vor: setzt alle Dateien auf den Stand
# vor dem Angriff zurueck (hebt die gefaelschten Aenderungen auf) und den Anker in
# v1.yml auf den Angriffs-Merge. Committet wird signiert von Lukas.
prepare_app_anchor() {
  local base="$1" anchor="$2"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  git -C "$EXAMPLE_APP_DIR" switch --quiet -C "$ANCHOR_BRANCH_APP" origin/main
  git -C "$EXAMPLE_APP_DIR" checkout "$base" -- .
  set_anchor "$EXAMPLE_APP_DIR/.github/workflows/v1.yml" "$anchor"
  git -C "$EXAMPLE_APP_DIR" add -A
}

# --- Ablauf ------------------------------------------------------------------

STATE="ak0203"
PHASE_FILE="$STATE_DIR/$STATE.phase"
mkdir -p "$STATE_DIR"
PHASE=fresh
# shellcheck source=/dev/null
[ -f "$PHASE_FILE" ] && source "$PHASE_FILE"
[ "${ANGRIFF:-}" = neu ] && PHASE=fresh

if [ "$PHASE" = fresh ]; then
  step "Stand vor dem Angriff festhalten"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  BASE="$(git -C "$EXAMPLE_APP_DIR" rev-parse origin/main)"
  info "Basis: ${BASE:0:7}"

  step "Fall gefaelschter-autor: Commit mit gefaelschtem Autor nach main"
  forged_merge ak0203-gefaelschter-autor \
    "AK-02/03: Commit mit gefaelschtem Autor" forge_harmless_change
  record_push_builds "${STATE}-autor" "$MERGE_COMMIT"

  step "Fall pruefung-entfernt: gefaelschter Autor und Commit-Pruefung aus v1.yml entfernt"
  forged_merge ak0203-pruefung-entfernt \
    "AK-02/03: Commit-Pruefung aus dem App-Workflow entfernt" forge_and_remove_check
  record_push_builds "${STATE}-pruefung" "$MERGE_COMMIT"
  ANCHOR="$MERGE_COMMIT"

  step "Wiederherstellung 1/2: Vertrauensanker in secure-workflows verschieben"
  move_platform_anchor "$ANCHOR"

  step "Wiederherstellung 2/2 vorbereiten: Anker in example-app/v1.yml"
  prepare_app_anchor "$BASE" "$ANCHOR"
  printf 'PHASE=restore-prepared\n' > "$PHASE_FILE"
  print_sign_prompt "$ANCHOR_BRANCH_APP" \
    "AK-02/03 Wiederherstellung: Code zuruecksetzen und Vertrauensanker verschieben" "$AK_FLAG"
  exit 0
fi

if [ "$PHASE" = restore-prepared ]; then
  if ! has_signed_commit "$ANCHOR_BRANCH_APP"; then
    print_sign_prompt "$ANCHOR_BRANCH_APP" \
      "AK-02/03 Wiederherstellung: Code zuruecksetzen und Vertrauensanker verschieben" "$AK_FLAG"
    exit 0
  fi
  step "Wiederherstellung 2/2: Anker-Commit in example-app nach main"
  open_and_merge_pr "$EXAMPLE_APP_REPO" "$ANCHOR_BRANCH_APP" \
    "AK-02/03 Wiederherstellung: Vertrauensanker verschieben" "$EXAMPLE_APP_DIR"
  verify_restore_green "$MERGE_COMMIT"
  printf 'PHASE=done\n' > "$PHASE_FILE"
fi

# PHASE=done: beide Faelle gegen die laufende Variante auswerten.
evaluate_from_state "$AK" gefaelschter-autor V1 "${STATE}-autor"
evaluate_from_state "$AK" pruefung-entfernt V2 "${STATE}-pruefung"
