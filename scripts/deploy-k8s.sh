#!/usr/bin/env bash
# Deploy (or upgrade) the application with Helm using immutable image tags, wait until every pod
# of the new release is Ready, and roll back to the last good Helm revision if it is not.
#
#   ./scripts/deploy-k8s.sh <registry> <tag> [extra helm args...]
#   ./scripts/deploy-k8s.sh 123456789012.dkr.ecr.ap-south-1.amazonaws.com 42-a1b2c3d
#   ./scripts/deploy-k8s.sh local v2 -f helm/order-inventory/values-minikube.yaml
#
# Env: K8S_NAMESPACE (default order-inventory), RELEASE (default order-inventory),
#      ROLLOUT_TIMEOUT (default 5m), DB_SECRET (default mysql-secret).
# Exit codes: 0 deployed and healthy; 1 failed (rolled back when a previous revision existed).
# Prerequisites (one-time, see docs/RUNBOOKS.md): namespace, mysql-secret, AWS LB Controller (EKS).
set -euo pipefail

REGISTRY="${1:?usage: deploy-k8s.sh <registry> <tag> [helm args...]}"
TAG="${2:?usage: deploy-k8s.sh <registry> <tag> [helm args...]}"
shift 2
NAMESPACE="${K8S_NAMESPACE:-order-inventory}"
RELEASE="${RELEASE:-order-inventory}"
TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$REPO_ROOT/helm/order-inventory"
STATE_DIR="$REPO_ROOT/.deploy"
mkdir -p "$STATE_DIR"

[ "$TAG" != "latest" ] || { echo "Refusing to deploy the mutable tag 'latest'" >&2; exit 1; }
kubectl get namespace "$NAMESPACE" >/dev/null || { echo "Namespace $NAMESPACE missing: kubectl apply -f k8s/namespace.yaml" >&2; exit 1; }

# Database connection secret (chart value database.existingSecret, default mysql-secret)
kubectl -n "$NAMESPACE" get secret "${DB_SECRET:-mysql-secret}" >/dev/null \
  || { echo "Secret ${DB_SECRET:-mysql-secret} missing: run scripts/create-db-secret.sh" >&2; exit 1; }

# Last successfully deployed revision (empty on first install, when `helm history` fails)
PREV_REVISION="$(helm -n "$NAMESPACE" history "$RELEASE" -o json 2>/dev/null \
  | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const h=JSON.parse(d).filter(r=>r.status==="deployed"||r.status==="superseded");const dep=h.filter(r=>r.status==="deployed");const r=(dep.length?dep:h).pop();console.log(r?r.revision:"")}catch{console.log("")}})' || true)"
echo "PREV_REVISION=${PREV_REVISION}" > "$STATE_DIR/previous-revision"

echo "Deploying ${REGISTRY}/order-inventory-{backend,frontend}:${TAG} (release ${RELEASE}, namespace ${NAMESPACE}, previous revision ${PREV_REVISION:-none})"

if helm upgrade --install "$RELEASE" "$CHART" \
     --namespace "$NAMESPACE" \
     --set image.registry="$REGISTRY" \
     --set image.tag="$TAG" \
     --wait --timeout "$TIMEOUT" \
     "$@"; then
  for d in backend frontend; do
    kubectl -n "$NAMESPACE" rollout status "deployment/$d" --timeout=60s
  done
  echo "Release healthy:"
  kubectl -n "$NAMESPACE" get deployments -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image'
  exit 0
fi

echo "Deployment of ${TAG} failed (pods not Ready within ${TIMEOUT})." >&2
kubectl -n "$NAMESPACE" get pods -o wide >&2 || true
kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | tail -15 >&2 || true

if [ -n "$PREV_REVISION" ]; then
  echo "Rolling back ${RELEASE} to revision ${PREV_REVISION}..." >&2
  helm -n "$NAMESPACE" rollback "$RELEASE" "$PREV_REVISION" --wait --timeout "$TIMEOUT" >&2
  kubectl -n "$NAMESPACE" get deployments -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image' >&2
else
  echo "No previous revision (first install); leaving resources in place for diagnosis." >&2
fi
exit 1
