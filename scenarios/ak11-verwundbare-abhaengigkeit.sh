#!/usr/bin/env bash
# AK-11: Verwundbare Abhaengigkeit.
# Der Angreifer fuegt der Anwendung eine Bibliothek mit bekannter Schwachstelle
# hinzu (Werkzeug 0.15.2). V0 bis V2 bauen und signieren das Image ohne Pruefung,
# es wird an der Admission durchgelassen. V3 laesst Syft eine SBOM erzeugen, Grype
# findet die Schwachstelle und das Schwachstellen-Gate schlaegt fehl: der
# attest-Job laeuft nicht, das Image bleibt unsigniert und wird an der Admission
# abgelehnt.
#
# Werkzeug 0.15.2 wird ueber GHSA-j544-7q9p-6xp8 (EPSS ueber dem Schwellenwert 0.1)
# blockiert und hat keine Transitiv-Abhaengigkeiten, bleibt also uebersichtlich.
# Robuster Fallback mit Critical-Befunden: Django 3.2.0. Der Datenbankstand von
# Grype/KEV/EPSS wechselt taeglich und wird im Build-Log mitprotokolliert.
#
# Der Angriff braucht einen signierten Commit auf example-app/main (gitsign,
# Browser-Login von Lukas). Ablauf wie bei AK-10a ueber run_signed_app_scenario.
source "$(dirname "$0")/lib.sh"

AK="AK-11"
# shellcheck disable=SC2034 # AK_FLAG liest der Treiber in lib.sh (Re-Run-Hinweis)
AK_FLAG="11"
CASE="verwundbare-abhaengigkeit"
# Kap. 5 ordnet die verwundbare Abhaengigkeit dem Gate in Variante V3 zu.
HYPOTHESIS=V3
BRANCH="ak11-verwundbare-abhaengigkeit"
TITLE="AK-11: verwundbare Abhaengigkeit Werkzeug 0.15.2 hinzufuegen"
WERKZEUG_VERSION="0.15.2"

# Dasselbe Python-Image wie packages/build-internal-index.sh.
PYTHON_IMAGE="docker.io/library/python:3.14-slim@sha256:af8a5aa14780025dbfbcfbc81bd8a91ebd87711dd5b0f48ed71090949dd7cb1d"

describe "$AK" "Verwundbare Abhaengigkeit" \
  "Die Anwendung bekommt eine Abhaengigkeit mit bekannter Schwachstelle (Werkzeug $WERKZEUG_VERSION). Erwartet: In V0 bis V2 wird das Image gebaut, signiert und durchgelassen. In V3 schlaegt das Schwachstellen-Gate fehl, das Image bleibt unsigniert und wird an der Admission abgelehnt."

github_scenario_guard

# --- Angriff vorbereiten ------------------------------------------------------

# Legt das verwundbare Wheel in die interne Paketquelle (der Build erreicht kein
# echtes PyPI) und traegt die Abhaengigkeit in beide requirements-Dateien ein,
# in requirements.lock mit Hash, damit auch V3 sie installiert.
prepare_vulnerable_dependency() {
  local index="$EXAMPLE_APP_DIR/packages/internal/werkzeug"
  rm -rf "$index"
  mkdir -p "$index"

  docker run --rm -v "$index:/out" "$PYTHON_IMAGE" \
    pip download --quiet --only-binary=:all: --no-deps -d /out "werkzeug==$WERKZEUG_VERSION" >/dev/null
  local wheel hash
  wheel="$(basename "$index"/*.whl)"
  hash="$(docker run --rm -v "$index:/out" "$PYTHON_IMAGE" pip hash "/out/$wheel" | grep -o 'sha256:[0-9a-f]*')"

  # pip erwartet je Paket eine index.html mit Links (Simple Repository API).
  printf '<!DOCTYPE html>\n<html><body>\n<a href="%s">%s</a>\n</body></html>\n' "$wheel" "$wheel" \
    > "$index/index.html"

  printf 'werkzeug==%s\n' "$WERKZEUG_VERSION" >> "$EXAMPLE_APP_DIR/requirements.txt"
  printf '\nwerkzeug==%s \\\n    --hash=%s\n' "$WERKZEUG_VERSION" "$hash" >> "$EXAMPLE_APP_DIR/requirements.lock"
  info "Werkzeug $WERKZEUG_VERSION in die interne Quelle vendored, requirements erweitert."
}

# Auswertung: generisch. In V0 bis V2 ist das Image signiert und wird
# durchgelassen; in V3 ist es mangels bestandenem Gate unsigniert und wird an der
# Admission abgelehnt (dieselbe Wirkung wie ein fehlendes Image, hier aber
# sichtbar als Admission-Ablehnung statt als Build-Abbruch).
evaluate_ak11() {
  evaluate_from_state "$AK" "$CASE" "$HYPOTHESIS" ak11
}

run_signed_app_scenario ak11 "$BRANCH" "$TITLE" prepare_vulnerable_dependency evaluate_ak11
