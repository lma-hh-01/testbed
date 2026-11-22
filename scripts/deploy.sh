#!/usr/bin/env bash
# Brings the most recently successfully built version of the example application into the cluster:
#   1. Determine the commit of the variant's last successful pipeline run on GitHub
#   2. Copy the image including signatures and attestations from ghcr to zot
#   3. Apply the manifests from exactly this commit with the deployer identity
# The pipeline cannot reach the local cluster, so this script takes over
# transfer and deployment.
source "$(dirname "$0")/lib.sh"

[ -f "$WORK_DIR/variant" ] || fail "No testbed found. Run 'make cluster VARIANT=...' first."
VARIANT="$(cat "$WORK_DIR/variant")"

GHCR_IMAGE="ghcr.io/$GITHUB_OWNER/example-app-$VARIANT"
ZOT_REPOSITORY="example-app-$VARIANT"

find_last_successful_commit() {
  # status=success ensures that all jobs of the run have finished, including the attestation.
  local url="https://api.github.com/repos/$GITHUB_OWNER/example-app/actions/workflows/$VARIANT.yml/runs?branch=main&status=success&per_page=1"
  curl -fsSL "$url" | jq -r '.workflow_runs[0].head_sha // empty'
}

# ORAS gets a login file of its own. This leaves the Docker configuration of the
# host untouched, and ghcr is read anonymously.
copy_to_zot() {
  local source="$1"
  local target_tag="$2"
  oras cp --recursive \
    --from-registry-config "$ORAS_AUTH_FILE" --to-registry-config "$ORAS_AUTH_FILE" \
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

step "Look up the last successful build of variant $VARIANT on GitHub"
COMMIT="$(find_last_successful_commit)"
[ -n "$COMMIT" ] || fail "No successful run of $VARIANT.yml on main found."
info "Commit: $COMMIT"

step "Copy image from ghcr to zot"
if [ "$VARIANT" = "v0" ]; then
  # Baseline: distribution and deployment via the mutable tag "latest".
  copy_to_zot "$GHCR_IMAGE:latest" latest
  IMAGE_REF="$ZOT_CLUSTER_ADDRESS/$ZOT_REPOSITORY:latest"
else
  # From V1 on the image is identified and referenced by its digest.
  DIGEST="$(oras resolve --registry-config "$ORAS_AUTH_FILE" "$GHCR_IMAGE:$COMMIT")"
  copy_to_zot "$GHCR_IMAGE@$DIGEST" "$COMMIT"
  IMAGE_REF="$ZOT_CLUSTER_ADDRESS/$ZOT_REPOSITORY@$DIGEST"
fi
info "Image in the cluster: $IMAGE_REF"

step "Apply manifests from commit ${COMMIT:0:7}"
git -C "$EXAMPLE_APP_DIR" fetch --quiet origin main
render_deployment "$COMMIT" "$IMAGE_REF" | deployer_kubectl apply -f -
git -C "$EXAMPLE_APP_DIR" show "$COMMIT:k8s/service.yaml" | deployer_kubectl apply -f -

step "Wait until the application is running"
deployer_kubectl rollout status deployment/example-app --timeout 120s

step "Done: the application is available at http://localhost:8080"
