#!/usr/bin/env bash
# Shared settings and helper functions for all scripts of the testbed.
# The other scripts include this file with "source".
set -euo pipefail

TESTBED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTBED_DIR/versions.env"

# The three repositories sit next to each other in the same folder.
EXAMPLE_APP_DIR="$TESTBED_DIR/../example-app"
SECURE_WORKFLOWS_DIR="$TESTBED_DIR/../secure-workflows"
# Normalize the paths (without /../) so that printed commands stay readable.
[ -d "$EXAMPLE_APP_DIR" ] && EXAMPLE_APP_DIR="$(cd "$EXAMPLE_APP_DIR" && pwd)"
[ -d "$SECURE_WORKFLOWS_DIR" ] && SECURE_WORKFLOWS_DIR="$(cd "$SECURE_WORKFLOWS_DIR" && pwd)"
GITHUB_OWNER="lma-hh-01"

CLUSTER_NAME="testbed"
APP_NAMESPACE="example-app"

# Runtime data (passwords, kubeconfigs). Deleted by "make down".
WORK_DIR="$TESTBED_DIR/.work"
ADMIN_KUBECONFIG="$WORK_DIR/admin.kubeconfig"
DEPLOYER_KUBECONFIG="$WORK_DIR/deployer.kubeconfig"

# The registry zot is reachable from the host at localhost:5001 and from
# inside the cluster at zot.localhost:5000 (alias in the Docker network "kind").
# The .localhost suffix makes Kyverno talk to the registry without TLS,
# see start_zot in cluster-up.sh.
ZOT_CONTAINER="zot"
ZOT_HOST_ADDRESS="localhost:5001"
ZOT_CLUSTER_HOST="zot.localhost"
ZOT_CLUSTER_ADDRESS="$ZOT_CLUSTER_HOST:5000"
ZOT_USER="uploader"
ZOT_PASSWORD_FILE="$WORK_DIR/zot-password"
ORAS_AUTH_FILE="$WORK_DIR/oras-auth.json"

VARIANTS="v0 v1 v2 v3"

step() {
  printf '\n==> %s\n' "$*"
}

info() {
  printf '    %s\n' "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_variant() {
  local variant="$1"
  case " $VARIANTS " in
    *" $variant "*) ;;
    *) fail "Unknown variant '$variant'. Allowed are: $VARIANTS" ;;
  esac
}

admin_kubectl() {
  kubectl --kubeconfig "$ADMIN_KUBECONFIG" "$@"
}

deployer_kubectl() {
  kubectl --kubeconfig "$DEPLOYER_KUBECONFIG" "$@"
}
