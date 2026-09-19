#!/usr/bin/env bash
#
# One-command setup for the eb-demo-service take-home.
# Safe to run more than once (idempotent) — the grading harness runs it twice.
#
# Steps:
#   1. Create (or reuse) a kind cluster named "demo"
#   2. Install the ingress-nginx controller
#   3. Build the service image and load it into the cluster
#   4. helm upgrade --install the chart as release "demo" in namespace "demo"

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE_NAME="demo"
IMAGE_NAME="eb-demo-service"
IMAGE_TAG="1.0.0"
IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

for bin in docker kind kubectl helm; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: '$bin' is required but not found on PATH." >&2
    exit 1
  fi
done

# --- 1. kind cluster ---------------------------------------------------------
log "Checking for kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "Cluster '${CLUSTER_NAME}' already exists — reusing it."
else
  echo "Creating cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT_DIR}/kind-config.yaml"
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# --- 2. ingress-nginx --------------------------------------------------------
log "Checking ingress-nginx controller status"
if kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=5s >/dev/null 2>&1; then
  echo "ingress-nginx controller is already ready — skipping install/reapply."
else
  echo "Installing ingress-nginx controller"
  # kubectl apply is inherently idempotent — re-running just reconciles state.
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

  echo "Waiting for the ingress-nginx controller Deployment to exist..."
  # `kubectl wait` errors immediately with "no matching resources found" if the
  # pod doesn't exist yet — poll until at least one shows up before waiting on it.
  for i in $(seq 1 30); do
    if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null | grep -q controller; then
      break
    fi
    sleep 2
  done

  echo "Waiting for ingress-nginx controller to be ready..."
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s
fi

# --- 3. build + load image ---------------------------------------------------
log "Building image ${IMAGE}"
docker build -t "${IMAGE}" "${ROOT_DIR}/service"

log "Loading image into kind cluster '${CLUSTER_NAME}'"
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}"

# --- 4. namespace + helm release --------------------------------------------
log "Ensuring namespace '${NAMESPACE}' exists"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log "Deploying chart as release '${RELEASE_NAME}'"
helm upgrade --install "${RELEASE_NAME}" "${ROOT_DIR}/chart" \
  --namespace "${NAMESPACE}" \
  --set image.repository="${IMAGE_NAME}" \
  --set image.tag="${IMAGE_TAG}" \
  --wait --timeout 120s

log "Done"
cat <<EOF

Service is deployed. To reach it through the Ingress:

  1. Add this to /etc/hosts (one-time, needs sudo):
       127.0.0.1 demo.local

  2. Then:
       curl http://demo.local/
       curl http://demo.local/healthz

Or skip /etc/hosts entirely:
       curl -H "Host: demo.local" http://127.0.0.1/

EOF