#!/usr/bin/env bash
# AK-10 (part a): Dependency confusion.
# The attacker puts a package with the same name company-utils in a higher
# version (99.0.0) into the "public" package index packages/public/. Without
# hashes pip picks the highest version across several indexes and thus pulls the
# planted package. V0 to V2 build it in (the page then shows 99.0.0), the image
# is signed regularly and allowed at admission (limit of AF-13). V3 installs via
# requirements.lock with --require-hashes and keeps 1.0.0 from the internal
# index, so it is defended not by an abort but by the correct selection.
#
# The attack needs a signed commit on example-app/main (gitsign, browser login
# by Lukas). The driver run_signed_app_scenario prepares the change, prints the
# commit command, brings it to main via a PR after signing, evaluates the builds
# and restores via a revert.
source "$(dirname "$0")/lib.sh"

AK="AK-10"
# shellcheck disable=SC2034 # AK_FLAG is read by the driver in lib.sh (re-run hint)
AK_FLAG="10a"
CASE="dependency-confusion"
# Chapter 5 assigns dependency confusion to variant V3 (lockfile with hash).
HYPOTHESIS=V3
BRANCH="ak10a-dependency-confusion"
TITLE="AK-10a: plant company-utils 99.0.0 in the public package index"

# The same Python image as packages/build-internal-index.sh, so that the wheel
# is built exactly like the legitimate package.
PYTHON_IMAGE="docker.io/library/python:3.14-slim@sha256:af8a5aa14780025dbfbcfbc81bd8a91ebd87711dd5b0f48ed71090949dd7cb1d"

describe "$AK" "Dependency confusion" \
  "A package with the same name company-utils 99.0.0 is put into the public package index. Expected: in V0 to V2 pip installs the higher version (the page shows 99.0.0), the signed image is allowed. In V3 the lockfile with hash pins 1.0.0, the page keeps showing 1.0.0."

github_scenario_guard

# --- Prepare the attack -------------------------------------------------------

# Builds company-utils 99.0.0 as a wheel and stores it together with a simple
# repository index in packages/public/. A marker in SOURCE makes the origin
# visible on the page.
prepare_dependency_confusion() {
  local public="$EXAMPLE_APP_DIR/packages/public/company-utils"
  local src="$SCENARIO_DIR/ak10a-src"
  rm -rf "$src" "$public"
  mkdir -p "$src/company_utils" "$public"

  cat > "$src/pyproject.toml" <<'TOML'
[project]
name = "company-utils"
version = "99.0.0"
description = "Planted package from the public index (AK-10a)"
requires-python = ">=3.12"

[build-system]
requires = ["setuptools>=61"]
build-backend = "setuptools.build_meta"
TOML
  cat > "$src/company_utils/__init__.py" <<'PY'
__version__ = "99.0.0"

SOURCE = "public package index (attack)"
PY

  docker run --rm -v "$src:/src" -v "$public:/out" -w /src "$PYTHON_IMAGE" \
    pip wheel --quiet --disable-pip-version-check --no-deps . -w /out >/dev/null

  # pip expects one index.html per package with links (Simple Repository API).
  {
    echo "<!DOCTYPE html>"
    echo "<html><body>"
    local wheel
    for wheel in "$public"/*.whl; do
      printf '<a href="%s">%s</a>\n' "$(basename "$wheel")" "$(basename "$wheel")"
    done
    echo "</body></html>"
  } > "$public/index.html"
  info "company-utils 99.0.0 stored in packages/public/."
}

# --- Evaluation per variant ---------------------------------------------------

# Deploys the attack image of the running variant, opens the page and reads the
# built-in company-utils version. V3 is defended if 1.0.0 keeps running.
evaluate_dependency_confusion() {
  load_variant_state ak10a
  if [ "$SV_RESULT" = build-aborted ]; then
    RESULT=build-aborted
    record_result "$AK" "$CASE" "$HYPOTHESIS" "$RESULT" "$SV_NOTE" "no image built"
    return
  fi

  step "Deploy the attack image (commit ${SV_DEPLOY:0:7}) and open the page"
  git -C "$EXAMPLE_APP_DIR" fetch --quiet origin >/dev/null 2>&1 || true
  deploy_commit_to_cluster "$VARIANT" "$SV_DEPLOY" "$SV_TAG"
  info "Image in the cluster: $DEPLOY_IMAGE"

  local manifest="$SCENARIO_DIR/ak10a.yaml"
  render_app_deployment "$SV_DEPLOY" "$DEPLOY_IMAGE" > "$manifest"
  deployer_kubectl apply -f "$manifest" >/dev/null
  git -C "$EXAMPLE_APP_DIR" show "$SV_DEPLOY:k8s/service.yaml" | deployer_kubectl apply -f - >/dev/null
  deployer_kubectl rollout status deployment/example-app --timeout 120s >/dev/null

  # Wait for the attack pod: rollout status returns before the old pod (from
  # make deploy) is gone. Only once the page shows the deployed image reference
  # of the attack is the company-utils version read. pipefail (from lib.sh)
  # would otherwise abort on the empty grep, hence catch it per attempt.
  local page="" line=""
  for _ in $(seq 1 30); do
    page="$(curl -fsS http://localhost:8080/ 2>/dev/null || true)"
    if grep -qF "$DEPLOY_IMAGE" <<<"$page"; then
      line="$(grep -o 'company-utils</th><td>[^<]*' <<<"$page" | sed 's/.*<td>//' || true)"
      break
    fi
    sleep 2
  done
  info "The page shows company-utils: ${line:-unknown}"

  case "$line" in
    1.0.0*) RESULT=correct-version
            DETAIL="lockfile with hash: still company-utils 1.0.0 (internal package index)" ;;
    99.0.0*) RESULT=allowed
             DETAIL="company-utils 99.0.0 (public package index) in the cluster" ;;
    *) RESULT=allowed
       DETAIL="unexpected company-utils version: ${line:-unknown}" ;;
  esac
  record_result "$AK" "$CASE" "$HYPOTHESIS" "$RESULT" "$DETAIL" "$DEPLOY_IMAGE"

  deployer_kubectl delete -f "$manifest" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

run_signed_app_scenario ak10a "$BRANCH" "$TITLE" prepare_dependency_confusion evaluate_dependency_confusion
