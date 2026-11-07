#!/usr/bin/env bash
# Baut das Testbed vollstaendig ab: Cluster, Registry und Laufzeitdaten.
source "$(dirname "$0")/lib.sh"

step "kind-Cluster '$CLUSTER_NAME' loeschen"
kind delete cluster --name "$CLUSTER_NAME"

step "Registry zot entfernen"
docker rm -f "$ZOT_CONTAINER" >/dev/null 2>&1 || true

step "Laufzeitdaten loeschen ($WORK_DIR)"
rm -rf "$WORK_DIR"

step "Fertig"
