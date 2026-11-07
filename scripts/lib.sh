#!/usr/bin/env bash
# Gemeinsame Einstellungen und Hilfsfunktionen fuer alle Skripte des Testbeds.
# Wird von den anderen Skripten mit "source" eingebunden.
set -euo pipefail

TESTBED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTBED_DIR/versions.env"

# Die drei Repositories liegen nebeneinander im selben Ordner.
EXAMPLE_APP_DIR="$TESTBED_DIR/../example-app"
SECURE_WORKFLOWS_DIR="$TESTBED_DIR/../secure-workflows"
GITHUB_OWNER="lma-hh-01"

CLUSTER_NAME="testbed"
APP_NAMESPACE="example-app"

# Laufzeitdaten (Zertifikate, Passwoerter, kubeconfigs). Wird von "make down" geloescht.
WORK_DIR="$TESTBED_DIR/.work"
ADMIN_KUBECONFIG="$WORK_DIR/admin.kubeconfig"
DEPLOYER_KUBECONFIG="$WORK_DIR/deployer.kubeconfig"

# Die Registry zot ist vom Rechner aus unter localhost:5001 erreichbar,
# aus dem Cluster heraus unter zot:5000 (Container-Name im Docker-Netz "kind").
ZOT_CONTAINER="zot"
ZOT_HOST_ADDRESS="localhost:5001"
ZOT_CLUSTER_ADDRESS="zot:5000"
ZOT_USER="uploader"
TLS_DIR="$WORK_DIR/tls"
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
  printf '\nFEHLER: %s\n' "$*" >&2
  exit 1
}

require_variant() {
  local variant="$1"
  case " $VARIANTS " in
    *" $variant "*) ;;
    *) fail "Unbekannte Variante '$variant'. Erlaubt sind: $VARIANTS" ;;
  esac
}

admin_kubectl() {
  kubectl --kubeconfig "$ADMIN_KUBECONFIG" "$@"
}

deployer_kubectl() {
  kubectl --kubeconfig "$DEPLOYER_KUBECONFIG" "$@"
}
