#!/usr/bin/env bash
# Bringt den zuletzt erfolgreich gebauten Stand der Beispielanwendung in den Cluster:
#   1. Commit des letzten erfolgreichen Pipeline-Laufs der Variante auf GitHub ermitteln
#   2. Image samt Signaturen und Attestierungen von ghcr nach zot kopieren
#   3. Manifeste aus genau diesem Commit mit der Deployer-Identitaet anwenden
# Die Pipeline kann den lokalen Cluster nicht erreichen, deshalb uebernimmt dieses
# Skript Uebertragung und Deployment.
source "$(dirname "$0")/lib.sh"

[ -f "$WORK_DIR/variant" ] || fail "Kein Testbed gefunden. Erst 'make cluster VARIANT=...' ausfuehren."
VARIANT="$(cat "$WORK_DIR/variant")"

GHCR_IMAGE="ghcr.io/$GITHUB_OWNER/example-app-$VARIANT"
ZOT_REPOSITORY="example-app-$VARIANT"

find_last_successful_commit() {
  # status=success stellt sicher, dass alle Jobs des Laufs fertig sind, auch die Attestierung.
  local url="https://api.github.com/repos/$GITHUB_OWNER/example-app/actions/workflows/$VARIANT.yml/runs?branch=main&status=success&per_page=1"
  curl -fsSL "$url" | jq -r '.workflow_runs[0].head_sha // empty'
}

# ORAS bekommt eine eigene Login-Datei. Damit bleibt die Docker-Konfiguration des
# Rechners unberuehrt, und ghcr wird anonym gelesen. localhost spricht ORAS sonst
# automatisch ohne TLS an.
copy_to_zot() {
  local source="$1"
  local target_tag="$2"
  oras cp --recursive \
    --from-registry-config "$ORAS_AUTH_FILE" --to-registry-config "$ORAS_AUTH_FILE" \
    --to-plain-http=false --to-ca-file "$TLS_DIR/ca.crt" \
    "$source" "$ZOT_HOST_ADDRESS/$ZOT_REPOSITORY:$target_tag" >/dev/null
}

render_deployment() {
  local commit="$1"
  local image="$2"
  git -C "$EXAMPLE_APP_DIR" show "$commit:k8s/deployment.yaml" | IMAGE="$image" yq '
    (.spec.template.spec.containers[0].image = strenv(IMAGE)) |
    (.spec.template.spec.containers[0].env[] | select(.name == "DEPLOYED_IMAGE") | .value) = strenv(IMAGE)
  '
}

step "Letzten erfolgreichen Build der Variante $VARIANT auf GitHub suchen"
COMMIT="$(find_last_successful_commit)"
[ -n "$COMMIT" ] || fail "Kein erfolgreicher Lauf von $VARIANT.yml auf main gefunden."
info "Commit: $COMMIT"

step "Image von ghcr nach zot kopieren"
if [ "$VARIANT" = "v0" ]; then
  # Basislinie: Verteilung und Deployment ueber den veraenderlichen Tag "latest".
  copy_to_zot "$GHCR_IMAGE:latest" latest
  IMAGE_REF="$ZOT_CLUSTER_ADDRESS/$ZOT_REPOSITORY:latest"
else
  # Ab V1 wird das Image ueber seinen Digest bestimmt und referenziert.
  DIGEST="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$GHCR_IMAGE:$COMMIT")"
  copy_to_zot "$GHCR_IMAGE@$DIGEST" "$COMMIT"
  IMAGE_REF="$ZOT_CLUSTER_ADDRESS/$ZOT_REPOSITORY@$DIGEST"
fi
info "Image im Cluster: $IMAGE_REF"

step "Manifeste aus Commit ${COMMIT:0:7} anwenden"
git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
render_deployment "$COMMIT" "$IMAGE_REF" | deployer_kubectl apply -f -
git -C "$EXAMPLE_APP_DIR" show "$COMMIT:k8s/service.yaml" | deployer_kubectl apply -f -

step "Warten, bis die Anwendung laeuft"
deployer_kubectl rollout status deployment/example-app --timeout 120s

step "Fertig: Die Anwendung ist unter http://localhost:8080 erreichbar"
