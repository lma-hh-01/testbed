#!/usr/bin/env bash
# AK-10 (Teil a): Dependency Confusion.
# Der Angreifer legt ein gleichnamiges Paket firma-utils in hoeherer Version
# (99.0.0) in die "oeffentliche" Paketquelle packages/public/. pip ohne Hashes
# waehlt ueber mehrere Indizes den hoechsten Versionsstand und zieht damit das
# untergeschobene Paket. V0 bis V2 bauen es ein (die Seite zeigt dann 99.0.0),
# das Image ist regulaer signiert und wird an der Admission durchgelassen (Grenze
# von AF-13). V3 installiert ueber requirements.lock mit --require-hashes
# weiterhin 1.0.0 aus der internen Quelle und ist damit nicht durch Abbruch,
# sondern durch die korrekte Auswahl verteidigt.
#
# Der Angriff braucht einen signierten Commit auf example-app/main (gitsign,
# Browser-Login von Lukas). Der Treiber run_signed_app_scenario bereitet die
# Aenderung vor, nennt den Commit-Befehl, bringt sie nach dem Signieren per PR auf
# main, wertet die Builds aus und stellt per Revert wieder her.
source "$(dirname "$0")/lib.sh"

AK="AK-10"
# shellcheck disable=SC2034 # AK_FLAG liest der Treiber in lib.sh (Re-Run-Hinweis)
AK_FLAG="10a"
CASE="dependency-confusion"
# Kap. 5 ordnet Dependency Confusion der Variante V3 zu (Lockfile mit Hash).
HYPOTHESIS=V3
BRANCH="ak10a-dependency-confusion"
TITLE="AK-10a: firma-utils 99.0.0 in die oeffentliche Paketquelle einschleusen"

# Dasselbe Python-Image wie packages/build-internal-index.sh, damit das Wheel
# genauso gebaut wird wie das legitime Paket.
PYTHON_IMAGE="docker.io/library/python:3.14-slim@sha256:af8a5aa14780025dbfbcfbc81bd8a91ebd87711dd5b0f48ed71090949dd7cb1d"

describe "$AK" "Dependency Confusion" \
  "Ein gleichnamiges Paket firma-utils 99.0.0 wird in die oeffentliche Paketquelle gelegt. Erwartet: In V0 bis V2 installiert pip die hoehere Version (Seite zeigt 99.0.0), das signierte Image wird durchgelassen. In V3 pinnt das Lockfile mit Hash auf 1.0.0, die Seite zeigt weiter 1.0.0."

github_scenario_guard

# --- Angriff vorbereiten ------------------------------------------------------

# Baut firma-utils 99.0.0 als Wheel und legt es samt Simple-Repository-Index in
# packages/public/ ab. Marker in SOURCE macht die Herkunft auf der Seite sichtbar.
prepare_dependency_confusion() {
  local public="$EXAMPLE_APP_DIR/packages/public/firma-utils"
  local src="$SCENARIO_DIR/ak10a-src"
  rm -rf "$src" "$public"
  mkdir -p "$src/firma_utils" "$public"

  cat > "$src/pyproject.toml" <<'TOML'
[project]
name = "firma-utils"
version = "99.0.0"
description = "Untergeschobenes Paket aus der oeffentlichen Quelle (AK-10a)"
requires-python = ">=3.12"

[build-system]
requires = ["setuptools>=61"]
build-backend = "setuptools.build_meta"
TOML
  cat > "$src/firma_utils/__init__.py" <<'PY'
__version__ = "99.0.0"

SOURCE = "oeffentliche Paketquelle (Angriff)"
PY

  docker run --rm -v "$src:/src" -v "$public:/out" -w /src "$PYTHON_IMAGE" \
    pip wheel --quiet --disable-pip-version-check --no-deps . -w /out >/dev/null

  # pip erwartet je Paket eine index.html mit Links (Simple Repository API).
  {
    echo "<!DOCTYPE html>"
    echo "<html><body>"
    local wheel
    for wheel in "$public"/*.whl; do
      printf '<a href="%s">%s</a>\n' "$(basename "$wheel")" "$(basename "$wheel")"
    done
    echo "</body></html>"
  } > "$public/index.html"
  info "firma-utils 99.0.0 in packages/public/ abgelegt."
}

# --- Auswertung je Variante ---------------------------------------------------

# Deployt das Angriffs-Image der laufenden Variante, oeffnet die Seite und liest
# die eingebaute firma-utils-Version. V3 ist verteidigt, wenn weiter 1.0.0 laeuft.
evaluate_dependency_confusion() {
  load_variant_state ak10a
  if [ "$SV_RESULT" = build-abgebrochen ]; then
    RESULT=build-abgebrochen
    record_result "$AK" "$CASE" "$HYPOTHESIS" "$RESULT" "$SV_NOTE" "kein Image gebaut"
    return
  fi

  step "Angriffs-Image (Commit ${SV_DEPLOY:0:7}) deployen und Seite oeffnen"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin >/dev/null 2>&1 || true
  deploy_commit_to_cluster "$VARIANT" "$SV_DEPLOY" "$SV_TAG"
  info "Image im Cluster: $DEPLOY_IMAGE"

  local manifest="$SCENARIO_DIR/ak10a.yaml"
  render_app_deployment "$SV_DEPLOY" "$DEPLOY_IMAGE" > "$manifest"
  deployer_kubectl apply -f "$manifest" >/dev/null
  git -C "$EXAMPLE_APP_DIR" show "$SV_DEPLOY:k8s/service.yaml" | deployer_kubectl apply -f - >/dev/null
  deployer_kubectl rollout status deployment/example-app --timeout 120s >/dev/null

  # Auf den Angriffs-Pod warten: rollout status kehrt zurueck, bevor der alte Pod
  # (aus make deploy) weg ist. Erst wenn die Seite die deployte Image-Referenz des
  # Angriffs zeigt, wird die firma-utils-Version gelesen. pipefail (aus lib.sh)
  # wuerde sonst am leeren grep abbrechen, deshalb je Versuch abfangen.
  local page="" line=""
  for _ in $(seq 1 30); do
    page="$(curl -fsS http://localhost:8080/ 2>/dev/null || true)"
    if grep -qF "$DEPLOY_IMAGE" <<<"$page"; then
      line="$(grep -o 'firma-utils</th><td>[^<]*' <<<"$page" | sed 's/.*<td>//' || true)"
      break
    fi
    sleep 2
  done
  info "Seite zeigt firma-utils: ${line:-unbekannt}"

  case "$line" in
    1.0.0*) RESULT=korrekte-auswahl
            DETAIL="Lockfile mit Hash: weiter firma-utils 1.0.0 (interne Paketquelle)" ;;
    99.0.0*) RESULT=durchgelassen
             DETAIL="firma-utils 99.0.0 (oeffentliche Paketquelle) im Cluster" ;;
    *) RESULT=durchgelassen
       DETAIL="unerwartete firma-utils-Version: ${line:-unbekannt}" ;;
  esac
  record_result "$AK" "$CASE" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$DEPLOY_IMAGE"

  deployer_kubectl delete -f "$manifest" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

run_signed_app_scenario ak10a "$BRANCH" "$TITLE" prepare_dependency_confusion evaluate_dependency_confusion
