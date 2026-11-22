#!/usr/bin/env bash
# Tears down the testbed completely: cluster, registry and runtime data.
source "$(dirname "$0")/lib.sh"

step "Delete kind cluster '$CLUSTER_NAME'"
kind delete cluster --name "$CLUSTER_NAME"

step "Remove registry zot"
docker rm -f "$ZOT_CONTAINER" >/dev/null 2>&1 || true
# Builder that scenarios with a local build create.
docker buildx rm testbed >/dev/null 2>&1 || true

step "Delete runtime data ($WORK_DIR)"
rm -rf "$WORK_DIR"

step "Done"
