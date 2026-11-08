#!/usr/bin/env bash
# Baut die lokale Umgebung fuer eine Toolchain-Variante auf:
# Registry zot (mit Login fuer Schreibzugriffe), kind-Cluster, Namespace der
# Anwendung mit eingeschraenkter Deployer-Identitaet und ab V1 Kyverno an der Admission.
#
# Aufruf: cluster-up.sh <variante>
source "$(dirname "$0")/lib.sh"

VARIANT="${1:?Aufruf: cluster-up.sh <variante>}"
require_variant "$VARIANT"

# --- Zugangsdaten -------------------------------------------------------------

create_zot_login() {
  step "Zugangsdaten fuer Schreibzugriffe auf zot erzeugen (Benutzer '$ZOT_USER')"
  openssl rand -hex 16 > "$ZOT_PASSWORD_FILE"
  docker run --rm "$HTPASSWD_IMAGE" htpasswd -Bbn -C 10 "$ZOT_USER" "$(cat "$ZOT_PASSWORD_FILE")" \
    > "$WORK_DIR/htpasswd"
}

# --- Registry -----------------------------------------------------------------

start_zot() {
  step "Registry zot starten"
  # zot laeuft ohne TLS. Kyverno 1.19 holt bei der Signaturpruefung einzelne
  # Manifeste immer ueber HTTPS, auch wenn unsichere Registries erlaubt sind.
  # Fuer Namen auf .localhost waehlt die darunterliegende Registry-Bibliothek
  # aber von sich aus HTTP. Deshalb bekommt zot im Docker-Netz "kind" diesen Alias.
  docker run -d --name "$ZOT_CONTAINER" --network kind \
    --network-alias "$ZOT_CLUSTER_HOST" \
    -p "127.0.0.1:5001:5000" \
    -v "$TESTBED_DIR/config/zot/config.json:/etc/zot/config.json:ro" \
    -v "$WORK_DIR/htpasswd:/etc/zot/htpasswd:ro" \
    "$ZOT_IMAGE" serve /etc/zot/config.json >/dev/null

  for _ in $(seq 1 20); do
    if curl -s -o /dev/null "http://$ZOT_HOST_ADDRESS/v2/"; then
      info "zot laeuft unter http://$ZOT_HOST_ADDRESS (im Cluster: $ZOT_CLUSTER_ADDRESS)."
      return
    fi
    sleep 1
  done
  fail "zot antwortet nicht. Log: docker logs $ZOT_CONTAINER"
}

login_to_zot() {
  oras login "$ZOT_HOST_ADDRESS" --registry-config "$ORAS_AUTH_FILE" \
    --username "$ZOT_USER" --password-stdin < "$ZOT_PASSWORD_FILE" >/dev/null
  info "ORAS ist fuer Schreibzugriffe angemeldet."
}

# --- Cluster ------------------------------------------------------------------

create_cluster() {
  step "kind-Cluster '$CLUSTER_NAME' anlegen"
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" \
    --config "$TESTBED_DIR/config/kind.yaml" --kubeconfig "$ADMIN_KUBECONFIG"
}

configure_zot_on_nodes() {
  step "containerd auf den Nodes fuer zot konfigurieren"
  # containerd laeuft ausserhalb von Kubernetes direkt im Node-Container und
  # versucht ohne diesen Eintrag HTTPS.
  local registry_dir="/etc/containerd/certs.d/$ZOT_CLUSTER_ADDRESS"
  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" mkdir -p "$registry_dir"
    docker exec -i "$node" cp /dev/stdin "$registry_dir/hosts.toml" <<EOF
[host."http://$ZOT_CLUSTER_ADDRESS"]
EOF
  done
}

create_deployer() {
  step "Namespace '$APP_NAMESPACE' und eingeschraenkte Identitaet 'deployer' anlegen"
  admin_kubectl apply -f "$TESTBED_DIR/config/rbac/deployer.yaml" >/dev/null
  # Pods ohne eigenes ServiceAccount brauchen "default", das Kubernetes erst kurz
  # nach dem Namespace anlegt. Sonst schlagen fruehe Deployments fehl.
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
  info "kubeconfig des Deployers: $DEPLOYER_KUBECONFIG"
}

# --- Kyverno (ab V1) ----------------------------------------------------------

install_kyverno() {
  step "Kyverno $KYVERNO_CHART_VERSION (Helm-Chart) installieren"
  helm upgrade --install kyverno kyverno \
    --repo https://kyverno.github.io/kyverno/ --version "$KYVERNO_CHART_VERSION" \
    --namespace kyverno --create-namespace --kubeconfig "$ADMIN_KUBECONFIG" \
    --wait --timeout 5m >/dev/null
  info "Kyverno laeuft."
}

apply_policies() {
  local policy_dir="$SECURE_WORKFLOWS_DIR/policies/$VARIANT"
  step "Kyverno-Richtlinien der Variante $VARIANT anwenden (aus secure-workflows)"
  admin_kubectl apply -f "$policy_dir"
  # Erst wenn Kyverno eine Richtlinie als bereit meldet, greift sie an der Admission.
  admin_kubectl wait -f "$policy_dir" \
    --for jsonpath='{.status.conditionStatus.ready}'=true --timeout 60s >/dev/null
  info "Richtlinien sind aktiv."
}

# --- Ablauf -------------------------------------------------------------------

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  fail "Es laeuft bereits ein Testbed. Erst mit 'make down' abbauen."
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

step "Fertig: Testbed fuer Variante $VARIANT steht"
info "Als Naechstes: make deploy"
