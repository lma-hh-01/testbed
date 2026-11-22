#!/usr/bin/env bash
# AK-05: Manipulation der Build-Eingabeparameter.
# Zwei Faelle:
#   (a) feature-branch: Der Angreifer startet den Build von einem inoffiziellen
#       Branch statt von main (workflow_dispatch). In V0 landet dessen Image im
#       Cluster, ab V1 bricht der Build im Schritt "Nur main bauen" ab.
#   (b) eigene-build-schritte: Der Angreifer aendert den Build auf main. In V1
#       liegt der Workflow im App-Repo, der injizierte Schritt wird mitsigniert
#       und durchgelassen. Ab V2 liegt der Build im zentralen Workflow, das
#       App-Repo kann ihn nicht mehr veraendern.
#
# Modell "einmal angreifen, je Variante auswerten": Der erste Aufruf greift einmal
# echt ueber GitHub an, haelt das Ergebnis je Variante fest und stellt wieder her.
# Jeder weitere Aufruf wertet nur die gerade laufende Variante aus. ANGRIFF=neu
# erzwingt einen neuen Angriff.
source "$(dirname "$0")/lib.sh"

AK="AK-05"
# shellcheck disable=SC2034 # AK_FLAG liest der Treiber in lib.sh (Re-Run-Hinweis)
AK_FLAG="05"
FEATURE_BRANCH="ak05-feature-branch"
INJECTED_VARIANT="ak05b-injiziert"

describe "$AK" "Manipulation der Build-Eingabeparameter" \
  "Fall (a): Build von einem inoffiziellen Feature-Branch per workflow_dispatch. Fall (b): eigene Build-Schritte auf main. Hypothese aus Kap. 5: abgewehrt ab V2. Erwartet laut Umsetzung: (a) schon ab V1 (es wird nur main gebaut), (b) ab V2 (zentraler Workflow)."

github_scenario_guard

# --- Fall (a): Build von einem inoffiziellen Feature-Branch -------------------

# Greift einmal an: legt den Feature-Branch an und startet dort je Variante einen
# Build. V0 baut durch, ab V1 bricht der Schritt "Nur main bauen" ab. Das Ergebnis
# je Variante wird festgehalten, der Branch bleibt als Angriffsartefakt stehen
# (er kann main nicht veraendern: kein Build auf main, kein Merge ohne Signatur).
attack_feature_branch() {
  step "Fall (a): Angriff ueber den inoffiziellen Branch '$FEATURE_BRANCH'"
  init_attack_state ak05a

  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
  git -C "$EXAMPLE_APP_DIR" switch --quiet -C "$FEATURE_BRANCH" origin/main
  # Ein eigener, bewusst unsignierter Commit macht den Branch-Build vom main-Build
  # unterscheidbar. Er wird nie gemergt und nie geprueft (ab V1 bricht der Build
  # vor jeder Pruefung ab, V0 prueft nicht).
  git -C "$EXAMPLE_APP_DIR" -c commit.gpgsign=false commit --quiet --allow-empty \
    -m "AK-05: Build von inoffiziellem Feature-Branch"
  git -C "$EXAMPLE_APP_DIR" push --quiet --force origin "$FEATURE_BRANCH"
  local branch_sha
  branch_sha="$(git -C "$EXAMPLE_APP_DIR" rev-parse HEAD)"
  git -C "$EXAMPLE_APP_DIR" switch --quiet main
  info "Branch-Commit: ${branch_sha:0:7} (unsigniert)"

  local variant
  for variant in v0 v1 v2 v3; do
    step "Fall (a): $variant.yml auf '$FEATURE_BRANCH' starten"
    dispatch_and_wait "$variant" "$FEATURE_BRANCH"
    info "Lauf $RUN_ID: $RUN_CONCLUSION"
    if [ "$RUN_CONCLUSION" = success ]; then
      set_variant_state "$variant" gebaut "$branch_sha" "$branch_sha" "Branch-Build erfolgreich"
    else
      set_variant_state "$variant" build-abgebrochen "" "" "Schritt: ${RUN_FAILED_STEPS:-unbekannt}"
    fi
  done
}

# Hypothese Fall (a): ab V1 (es wird nur main gebaut).
attack_done ak05a || attack_feature_branch
evaluate_from_state "$AK" feature-branch V1 ak05a

# --- Fall (b): eigene Build-Schritte auf main --------------------------------

# Schreibt einen Angreifer-Workflow, der den zentralen Aufruf durch einen eigenen
# Build-Job ersetzt: Das Image wird im App-Repo gebaut und gepusht, aber nicht mit
# der Identitaet des zentralen Workflows signiert.
write_eigener_build_job() {
  local variant="$1"
  cat > "$EXAMPLE_APP_DIR/.github/workflows/$variant.yml" <<YML
# AK-05b: Der zentrale Aufruf ist durch einen eigenen Build-Job ersetzt. Das Image
# wird im Anwendungs-Repository gebaut und gepusht, aber nicht mit der Identitaet
# des zentralen Workflows signiert.
name: $variant

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions: {}

env:
  IMAGE: ghcr.io/\${{ github.repository }}-$variant

jobs:
  build:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7

      - uses: docker/setup-buildx-action@v4

      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: \${{ github.actor }}
          password: \${{ secrets.GITHUB_TOKEN }}

      - name: Build-Zeit festhalten
        run: echo "BUILD_TIME=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "\$GITHUB_ENV"

      - uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/amd64
          push: true
          provenance: false
          sbom: false
          build-args: |
            APP_VARIANT=$INJECTED_VARIANT
            APP_COMMIT=\${{ github.sha }}
            APP_BUILD_TIME=\${{ env.BUILD_TIME }}
          labels: |
            org.opencontainers.image.source=\${{ github.server_url }}/\${{ github.repository }}
          tags: \${{ env.IMAGE }}:\${{ github.sha }}
YML
}

# Manipuliert den Build-Parameter einer Variante, die im App-Repo baut.
inject_build_arg() {
  local file="$EXAMPLE_APP_DIR/.github/workflows/$1.yml" variant="$1"
  sed "s/APP_VARIANT=$variant/APP_VARIANT=$INJECTED_VARIANT/" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# V0 und V1 bauen im App-Repo: ein manipulierter Build-Parameter reicht, das Image
# wird (in V1) mit der erwarteten Identitaet signiert und an der Admission
# akzeptiert. V2 und V3 bauen zentral: der Angreifer kann im App-Repo nur den
# Aufruf ersetzen, das so gebaute Image traegt nicht die zentrale Signatur.
prepare_own_build_steps() {
  inject_build_arg v0
  inject_build_arg v1
  write_eigener_build_job v2
  write_eigener_build_job v3
  info "Build-Parameter in v0/v1 manipuliert, zentraler Aufruf in v2/v3 ersetzt."
}

evaluate_ak05b() {
  evaluate_from_state "$AK" eigene-build-schritte V2 ak05b
}

# Hypothese Fall (b): ab V2 (Build liegt im zentralen Workflow).
run_signed_app_scenario ak05b ak05-eigene-build-schritte \
  "AK-05b: eigene Build-Schritte auf main (zentralen Aufruf ersetzen)" \
  prepare_own_build_steps evaluate_ak05b
