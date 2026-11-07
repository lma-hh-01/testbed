#!/usr/bin/env bash
# Baut die lokale Umgebung fuer eine Toolchain-Variante auf:
# Registry zot (mit TLS und Login), kind-Cluster, Namespace der Anwendung mit
# eingeschraenkter Deployer-Identitaet und ab V1 Kyverno an der Admission.
#
# Aufruf: cluster-up.sh <variante>
source "$(dirname "$0")/lib.sh"

VARIANT="${1:?Aufruf: cluster-up.sh <variante>}"
require_variant "$VARIANT"

# --- Zertifikate und Zugangsdaten ---------------------------------------------

create_certificates() {
  step "Eigene Zertifizierungsstelle und Zertifikat fuer zot erzeugen"
  mkdir -p "$TLS_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=testbed-ca" \
    -keyout "$TLS_DIR/ca.key" -out "$TLS_DIR/ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -config "$TESTBED_DIR/config/tls/server.cnf" \
    -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.csr" 2>/dev/null
  openssl x509 -req -days 30 -in "$TLS_DIR/server.csr" \
    -CA "$TLS_DIR/ca.crt" -CAkey "$TLS_DIR/ca.key" -CAcreateserial \
    -extfile "$TESTBED_DIR/config/tls/server.cnf" -extensions server \
    -out "$TLS_DIR/server.crt" 2>/dev/null
  # zot liest den Schluessel als unprivilegierter Benutzer im Container.
  chmod 644 "$TLS_DIR/server.key"
}

create_zot_login() {
  step "Zugangsdaten fuer Schreibzugriffe auf zot erzeugen (Benutzer '$ZOT_USER')"
  openssl rand -hex 16 > "$ZOT_PASSWORD_FILE"
  docker run --rm "$HTPASSWD_IMAGE" htpasswd -Bbn -C 10 "$ZOT_USER" "$(cat "$ZOT_PASSWORD_FILE")" \
    > "$WORK_DIR/htpasswd"
}

# --- Registry -----------------------------------------------------------------

start_zot() {
  step "Registry zot starten"
  # Im Docker-Netz "kind" (von kind angelegt) ist zot unter seinem Container-Namen erreichbar.
  docker run -d --name "$ZOT_CONTAINER" --network kind \
    -p "127.0.0.1:5001:5000" \
    -v "$TESTBED_DIR/config/zot/config.json:/etc/zot/config.json:ro" \
    -v "$TLS_DIR:/etc/zot/tls:ro" \
    -v "$WORK_DIR/htpasswd:/etc/zot/htpasswd:ro" \
    "$ZOT_IMAGE" serve /etc/zot/config.json >/dev/null

  for _ in $(seq 1 20); do
    if curl -s --cacert "$TLS_DIR/ca.crt" -o /dev/null "https://$ZOT_HOST_ADDRESS/v2/"; then
      info "zot laeuft unter https://$ZOT_HOST_ADDRESS (im Cluster: $ZOT_CLUSTER_ADDRESS)."
      return
    fi
    sleep 1
  done
  fail "zot antwortet nicht. Log: docker logs $ZOT_CONTAINER"
}

login_to_zot() {
  # ORAS spricht localhost sonst automatisch ohne TLS an.
  oras login "$ZOT_HOST_ADDRESS" --registry-config "$ORAS_AUTH_FILE" \
    --plain-http=false --ca-file "$TLS_DIR/ca.crt" \
    --username "$ZOT_USER" --password-stdin < "$ZOT_PASSWORD_FILE" >/dev/null
  info "ORAS ist fuer Schreibzugriffe angemeldet."
}

# --- Cluster ------------------------------------------------------------------

create_cluster() {
  step "kind-Cluster '$CLUSTER_NAME' anlegen"
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" \
    --config "$TESTBED_DIR/config/kind.yaml" --kubeconfig "$ADMIN_KUBECONFIG"
}

trust_zot_on_nodes() {
  step "containerd auf den Nodes fuer zot konfigurieren"
  # containerd laeuft ausserhalb von Kubernetes direkt im Node-Container und
  # braucht deshalb die CA und den Registry-Namen in seiner eigenen Konfiguration.
  local registry_dir="/etc/containerd/certs.d/$ZOT_CLUSTER_ADDRESS"
  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" mkdir -p "$registry_dir"
    docker cp "$TLS_DIR/ca.crt" "$node:$registry_dir/ca.crt"
    docker exec -i "$node" cp /dev/stdin "$registry_dir/hosts.toml" <<EOF
server = "https://$ZOT_CLUSTER_ADDRESS"

[host."https://$ZOT_CLUSTER_ADDRESS"]
  ca = "$registry_dir/ca.crt"
EOF
  done
}

create_deployer() {
  step "Namespace '$APP_NAMESPACE' und eingeschraenkte Identitaet 'deployer' anlegen"
  admin_kubectl apply -f "$TESTBED_DIR/config/rbac/deployer.yaml" >/dev/null

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
  info "kubeconfig des Deployers: $DEPLOYER_KUBECONFIG"
}

# --- Kyverno (ab V1) ----------------------------------------------------------

install_kyverno() {
  step "Kyverno $KYVERNO_CHART_VERSION (Helm-Chart) installieren"
  # Kyverno muss zot vertrauen. Die CA wird als ConfigMap bereitgestellt und
  # ueber values.yaml eingebunden. Helm kann sie nicht selbst anlegen, weil sie
  # erst in diesem Skript entsteht.
  admin_kubectl create namespace kyverno >/dev/null
  admin_kubectl create configmap testbed-ca --namespace kyverno \
    --from-file "ca.crt=$TLS_DIR/ca.crt" >/dev/null

  helm upgrade --install kyverno kyverno \
    --repo https://kyverno.github.io/kyverno/ --version "$KYVERNO_CHART_VERSION" \
    --namespace kyverno --kubeconfig "$ADMIN_KUBECONFIG" \
    --values "$TESTBED_DIR/config/kyverno/values.yaml" \
    --wait --timeout 5m >/dev/null
  info "Kyverno laeuft."
}

# --- Ablauf -------------------------------------------------------------------

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  fail "Es laeuft bereits ein Testbed. Erst mit 'make down' abbauen."
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
echo "$VARIANT" > "$WORK_DIR/variant"

create_certificates
create_zot_login
create_cluster
start_zot
login_to_zot
trust_zot_on_nodes
create_deployer

if [ "$VARIANT" != "v0" ]; then
  install_kyverno
fi

step "Fertig: Testbed fuer Variante $VARIANT steht"
info "Als Naechstes: make deploy"
