#!/usr/bin/env bash
# Sets up the local environment for one toolchain variant:
# registry zot (with a login for write access), kind cluster, namespace of the
# application with a restricted deployer identity and, from V1 on, Kyverno at admission.
#
# Usage: cluster-up.sh <variant>
source "$(dirname "$0")/lib.sh"

VARIANT="${1:?Usage: cluster-up.sh <variant>}"
require_variant "$VARIANT"

# --- Credentials --------------------------------------------------------------

create_zot_login() {
  step "Create credentials for write access to zot (user '$ZOT_USER')"
  openssl rand -hex 16 > "$ZOT_PASSWORD_FILE"
  docker run --rm "$HTPASSWD_IMAGE" htpasswd -Bbn -C 10 "$ZOT_USER" "$(cat "$ZOT_PASSWORD_FILE")" \
    > "$WORK_DIR/htpasswd"
}

# --- Registry -----------------------------------------------------------------

start_zot() {
  step "Start registry zot"
  # zot runs without TLS. During signature verification Kyverno 1.19 always
  # fetches single manifests via HTTPS, even if insecure registries are allowed.
  # For names ending in .localhost, however, the underlying registry library
  # chooses HTTP on its own. Hence zot gets this alias in the Docker network "kind".
  docker run -d --name "$ZOT_CONTAINER" --network kind \
    --network-alias "$ZOT_CLUSTER_HOST" \
    -p "127.0.0.1:5001:5000" \
    -v "$TESTBED_DIR/config/zot/config.json:/etc/zot/config.json:ro" \
    -v "$WORK_DIR/htpasswd:/etc/zot/htpasswd:ro" \
    "$ZOT_IMAGE" serve /etc/zot/config.json >/dev/null

  for _ in $(seq 1 20); do
    if curl -s -o /dev/null "http://$ZOT_HOST_ADDRESS/v2/"; then
      info "zot is running at http://$ZOT_HOST_ADDRESS (inside the cluster: $ZOT_CLUSTER_ADDRESS)."
      return
    fi
    sleep 1
  done
  fail "zot does not respond. Log: docker logs $ZOT_CONTAINER"
}

login_to_zot() {
  oras login "$ZOT_HOST_ADDRESS" --registry-config "$ORAS_AUTH_FILE" \
    --username "$ZOT_USER" --password-stdin < "$ZOT_PASSWORD_FILE" >/dev/null
  info "ORAS is logged in for write access."
}

# --- Cluster ------------------------------------------------------------------

create_cluster() {
  step "Create kind cluster '$CLUSTER_NAME'"
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" \
    --config "$TESTBED_DIR/config/kind.yaml" --kubeconfig "$ADMIN_KUBECONFIG"
}

configure_zot_on_nodes() {
  step "Configure containerd on the nodes for zot"
  # containerd runs outside of Kubernetes directly in the node container and
  # tries HTTPS without this entry.
  local registry_dir="/etc/containerd/certs.d/$ZOT_CLUSTER_ADDRESS"
  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" mkdir -p "$registry_dir"
    docker exec -i "$node" cp /dev/stdin "$registry_dir/hosts.toml" <<EOF
[host."http://$ZOT_CLUSTER_ADDRESS"]
EOF
  done
}

create_deployer() {
  step "Create namespace '$APP_NAMESPACE' and restricted identity 'deployer'"
  admin_kubectl apply -f "$TESTBED_DIR/config/rbac/deployer.yaml" >/dev/null
  # Pods without their own ServiceAccount need "default", which Kubernetes only
  # creates shortly after the namespace. Otherwise early deployments fail.
  until admin_kubectl get serviceaccount default --namespace "$APP_NAMESPACE" >/dev/null 2>&1; do
    sleep 1
  done

  local server
  server="$(admin_kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  admin_kubectl config view --raw --minify \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$WORK_DIR/cluster-ca.crt"

  local token
  token="$(admin_kubectl create token deployer --namespace "$APP_NAMESPACE" --duration 24h)"

  kubectl config set-cluster "$CLUSTER_NAME" --kubeconfig "$DEPLOYER_KUBECONFIG" \
    --server "$server" --certificate-authority "$WORK_DIR/cluster-ca.crt" --embed-certs >/dev/null
  kubectl config set-credentials deployer --kubeconfig "$DEPLOYER_KUBECONFIG" --token "$token" >/dev/null
  kubectl config set-context deployer --kubeconfig "$DEPLOYER_KUBECONFIG" \
    --cluster "$CLUSTER_NAME" --user deployer --namespace "$APP_NAMESPACE" >/dev/null
  kubectl config use-context deployer --kubeconfig "$DEPLOYER_KUBECONFIG" >/dev/null
  info "kubeconfig of the deployer: $DEPLOYER_KUBECONFIG"
}

# --- Kyverno (from V1 on) -----------------------------------------------------

install_kyverno() {
  step "Install Kyverno $KYVERNO_CHART_VERSION (Helm chart)"
  helm upgrade --install kyverno kyverno \
    --repo https://kyverno.github.io/kyverno/ --version "$KYVERNO_CHART_VERSION" \
    --namespace kyverno --create-namespace --kubeconfig "$ADMIN_KUBECONFIG" \
    --wait --timeout 5m >/dev/null
  info "Kyverno is running."
}

apply_policies() {
  local policy_dir="$SECURE_WORKFLOWS_DIR/policies/$VARIANT"
  step "Apply the Kyverno policies of variant $VARIANT (from secure-workflows)"
  # Right after the start the Kyverno validation webhook is sometimes not yet
  # reachable ("connection refused"), although the pods are running. Hence
  # repeat the apply until it succeeds.
  local attempt
  for attempt in $(seq 1 12); do
    admin_kubectl apply -f "$policy_dir" && break
    [ "$attempt" -lt 12 ] || fail "Kyverno webhook not reachable after several attempts."
    info "Kyverno webhook not ready yet, retrying ($attempt)..."
    sleep 5
  done
  # A policy only takes effect at admission once Kyverno reports it as ready.
  admin_kubectl wait -f "$policy_dir" \
    --for jsonpath='{.status.conditionStatus.ready}'=true --timeout 60s >/dev/null
  info "Policies are active."
}

# --- Procedure ----------------------------------------------------------------

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  fail "A testbed is already running. Tear it down first with 'make down'."
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
echo "$VARIANT" > "$WORK_DIR/variant"

create_zot_login
create_cluster
start_zot
login_to_zot
configure_zot_on_nodes
create_deployer

if [ "$VARIANT" != "v0" ]; then
  install_kyverno
  apply_policies
fi

step "Done: testbed for variant $VARIANT is up"
info "Next: make deploy"
