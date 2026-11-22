#!/usr/bin/env bash
# AK-11: Vulnerable dependency.
# The attacker adds a library with a known vulnerability to the application
# (Werkzeug 0.15.2). V0 to V2 build and sign the image without a check, it is
# allowed at admission. V3 lets Syft generate an SBOM, Grype finds the
# vulnerability and the vulnerability gate fails: the attest job does not run,
# the image stays unsigned and is denied at admission.
#
# Werkzeug 0.15.2 is blocked via GHSA-j544-7q9p-6xp8 (EPSS above the threshold
# 0.1) and has no transitive dependencies, so it stays easy to follow.
# Robust fallback with Critical findings: Django 3.2.0. The database state of
# Grype/KEV/EPSS changes daily and is logged in the build log.
#
# The attack needs a signed commit on example-app/main (gitsign, browser login
# by Lukas). Procedure as for AK-10a via run_signed_app_scenario.
source "$(dirname "$0")/lib.sh"

AK="AK-11"
# shellcheck disable=SC2034 # AK_FLAG is read by the driver in lib.sh (re-run hint)
AK_FLAG="11"
CASE="vulnerable-dependency"
# Chapter 5 assigns the vulnerable dependency to the gate in variant V3.
HYPOTHESIS=V3
BRANCH="ak11-vulnerable-dependency"
TITLE="AK-11: add the vulnerable dependency Werkzeug 0.15.2"
WERKZEUG_VERSION="0.15.2"

# The same Python image as packages/build-internal-index.sh.
PYTHON_IMAGE="docker.io/library/python:3.14-slim@sha256:af8a5aa14780025dbfbcfbc81bd8a91ebd87711dd5b0f48ed71090949dd7cb1d"

describe "$AK" "Vulnerable dependency" \
  "The application gets a dependency with a known vulnerability (Werkzeug $WERKZEUG_VERSION). Expected: in V0 to V2 the image is built, signed and allowed. In V3 the vulnerability gate fails, the image stays unsigned and is denied at admission."

github_scenario_guard

# --- Prepare the attack -------------------------------------------------------

# Puts the vulnerable wheel into the internal package index (the build cannot
# reach the real PyPI) and adds the dependency to both requirements files,
# in requirements.lock with a hash, so that V3 installs it as well.
prepare_vulnerable_dependency() {
  local index="$EXAMPLE_APP_DIR/packages/internal/werkzeug"
  rm -rf "$index"
  mkdir -p "$index"

  docker run --rm -v "$index:/out" "$PYTHON_IMAGE" \
    pip download --quiet --only-binary=:all: --no-deps -d /out "werkzeug==$WERKZEUG_VERSION" >/dev/null
  local wheel hash
  wheel="$(basename "$index"/*.whl)"
  hash="$(docker run --rm -v "$index:/out" "$PYTHON_IMAGE" pip hash "/out/$wheel" | grep -o 'sha256:[0-9a-f]*')"

  # pip expects one index.html per package with links (Simple Repository API).
  printf '<!DOCTYPE html>\n<html><body>\n<a href="%s">%s</a>\n</body></html>\n' "$wheel" "$wheel" \
    > "$index/index.html"

  printf 'werkzeug==%s\n' "$WERKZEUG_VERSION" >> "$EXAMPLE_APP_DIR/requirements.txt"
  printf '\nwerkzeug==%s \\\n    --hash=%s\n' "$WERKZEUG_VERSION" "$hash" >> "$EXAMPLE_APP_DIR/requirements.lock"
  info "Werkzeug $WERKZEUG_VERSION vendored into the internal index, requirements extended."
}

# Evaluation: generic. In V0 to V2 the image is signed and allowed; in V3 it is
# unsigned because the gate did not pass, and it is denied at admission (the
# same effect as a missing image, but visible here as an admission denial
# instead of a build abort).
evaluate_ak11() {
  evaluate_from_state "$AK" "$CASE" "$HYPOTHESIS" ak11
}

run_signed_app_scenario ak11 "$BRANCH" "$TITLE" prepare_vulnerable_dependency evaluate_ak11
