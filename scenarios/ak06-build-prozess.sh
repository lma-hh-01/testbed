#!/usr/bin/env bash
# AK-06: Kompromittierung des Build-Prozesses.
# Zwei Faelle:
#   Fall 1 (App-Repo): Neben dem regulaeren Build laeuft ein zusaetzlicher Job,
#     der ein manipuliertes Image baut und mit der Identitaet dieses App-Workflows
#     signiert. In V1 ist das die erwartete Identitaet, das Image wird akzeptiert.
#     Ab V2 liegt der Build im zentralen Workflow; der App-Job kann nur mit der
#     Identitaet des App-Repos signieren, die die Richtlinie nicht erwartet.
#   Fall 2 (zentraler Workflow): Ein Schritt im build-Job von secure-workflows
#     versucht zu signieren und scheitert, weil dieser Job kein id-token besitzt.
#     Beleg dafuer, dass Build und Signierung getrennt sind.
#
# Fall 1 braucht einen signierten Commit auf example-app/main (Ablauf wie AK-10a).
# Fall 2 laeuft ueber einen normalen PR in secure-workflows (keine Signatur).
source "$(dirname "$0")/lib.sh"

AK="AK-06"
# shellcheck disable=SC2034 # AK_FLAG liest der Treiber in lib.sh (Re-Run-Hinweis)
AK_FLAG="06"
BRANCH="ak06-build-prozess"
TITLE="AK-06: zusaetzlicher Job signiert ein manipuliertes Image"

describe "$AK" "Kompromittierung des Build-Prozesses" \
  "Ein zusaetzlicher Job baut ein manipuliertes Image und signiert es mit der Identitaet des App-Workflows. Erwartet: In V1 akzeptiert die Admission das Image (gleiche Identitaet), ab V2 lehnt sie ab, weil nur der zentrale Workflow signieren darf."

github_scenario_guard

# --- Fall 1: zusaetzlicher signierender Job im App-Repo -----------------------

# Haengt an einen App-Repo-Workflow einen manipulate-Job an, der nach dem
# regulaeren Build ein manipuliertes Image baut, es unter demselben Tag ablegt und
# (ausser in V0) mit der Identitaet dieses Workflows signiert. Das legitime und das
# manipulierte Image teilen sich den Commit-Tag; weil manipulate "needs: build"
# laeuft, zeigt der Tag am Ende auf das manipulierte Image.
manipulate_job() {
  local sign="$1"
  cat <<YML

  manipulate:
    needs: build
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
      id-token: write
    steps:
      - uses: actions/checkout@v7
      - uses: docker/setup-buildx-action@v4
      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: \${{ github.actor }}
          password: \${{ secrets.GITHUB_TOKEN }}
      - uses: sigstore/cosign-installer@v4.1.3
      - id: push
        uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/amd64
          push: true
          provenance: false
          sbom: false
          build-args: |
            APP_VARIANT=ak06-manipuliert
            APP_COMMIT=\${{ github.sha }}
          tags: \${{ env.IMAGE }}:\${{ github.sha }}
YML
  if [ "$sign" = sign ]; then
    cat <<'YML'
      - name: Manipuliertes Image mit der Identitaet dieses Workflows signieren
        run: cosign sign --yes "${{ env.IMAGE }}@${{ steps.push.outputs.digest }}"
YML
  fi
}

# V2 und V3 rufen den zentralen Workflow auf; der manipulate-Job wird daneben
# gesetzt (zentraler Aufruf bleibt). V0 und V1 bauen im App-Repo; dort wird der
# Job an den vorhandenen Workflow angehaengt.
write_v2v3_with_manipulate() {
  local variant="$1"
  cat > "$EXAMPLE_APP_DIR/.github/workflows/$variant.yml" <<YML
# AK-06 Fall 1: Der regulaere zentrale Aufruf bleibt, ein zusaetzlicher Job baut
# ein manipuliertes Image und signiert es mit der Identitaet dieses App-Workflows.
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
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      artifact-metadata: write
    uses: ${GITHUB_OWNER}/secure-workflows/.github/workflows/$variant.yml@main
$(manipulate_job sign)
YML
}

prepare_build_prozess() {
  manipulate_job "" >> "$EXAMPLE_APP_DIR/.github/workflows/v0.yml"
  manipulate_job sign >> "$EXAMPLE_APP_DIR/.github/workflows/v1.yml"
  write_v2v3_with_manipulate v2
  write_v2v3_with_manipulate v3
  info "Manipulate-Job an v0/v1 angehaengt, in v2/v3 neben den zentralen Aufruf gesetzt."
}

evaluate_ak06() {
  evaluate_from_state "$AK" app-repo-zusatzjob V2 ak06
}

# Hypothese Fall 1: ab V2 (Signatur nur noch durch den zentralen Workflow).
run_signed_app_scenario ak06 "$BRANCH" "$TITLE" prepare_build_prozess evaluate_ak06
