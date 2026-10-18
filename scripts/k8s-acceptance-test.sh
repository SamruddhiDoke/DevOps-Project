#!/usr/bin/env bash
# Kubernetes acceptance test for the Helm release on a LOCAL cluster (minikube).
# Verifies with real traffic and explicit assertions:
#   1. initial deployment + functional smoke test
#   2. rolling update v1 -> v2 under continuous load (expects zero failed requests)
#   3. bad image release -> deploy fails (exit 1) -> automatic rollback, no failed requests
#   4. failing readiness (health-check) release -> deploy fails -> rollback, no failed requests
#   5. database outage -> backend pods leave service WITHOUT restarting -> recover automatically
#   6. pod loss -> replacement becomes Ready
#
# Prerequisites: minikube running; images local/order-inventory-{backend,frontend}:{v1,v2}
# loaded (`minikube image load ...`). Uses namespace order-inventory and oi-testdb.
#   ./scripts/k8s-acceptance-test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS=order-inventory
VALUES="$REPO_ROOT/helm/order-inventory/values-minikube.yaml"
LOAD_SECONDS="${LOAD_SECONDS:-120}"
PASS=0

ok()   { PASS=$((PASS + 1)); echo "ok   - $*"; }
fail() { echo "FAIL: $*" >&2; kubectl -n "$NS" get pods -o wide >&2 || true; exit 1; }

CTX="$(kubectl config current-context)"
[ "$CTX" = "minikube" ] || [ "${ALLOW_CONTEXT:-}" = "$CTX" ] \
  || fail "current kube context is '$CTX'; this test only runs against minikube (set ALLOW_CONTEXT=$CTX to override)"

deploy() { "$REPO_ROOT/scripts/deploy-k8s.sh" local "$@" -f "$VALUES"; }
image_tag() { kubectl -n "$NS" get deploy "$1" -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://'; }
restarts() { kubectl -n "$NS" get pods -l app=backend -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}'; }
ready_backends() { kubectl -n "$NS" get pods -l app=backend -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true || true; }

# In-cluster load generator: requests the API through the frontend nginx for LOAD_SECONDS
start_load() {
  kubectl -n "$NS" delete pod "$1" --ignore-not-found --wait=true >/dev/null
  kubectl -n "$NS" run "$1" --image=curlimages/curl:8.10.1 --restart=Never --command -- sh -c \
    "end=\$(( \$(date +%s) + $LOAD_SECONDS )); while [ \$(date +%s) -lt \$end ]; do curl -s -o /dev/null -m 5 -w '%{http_code}\n' http://frontend/api/products; sleep 0.05; done" >/dev/null
  kubectl -n "$NS" wait --for=condition=Ready "pod/$1" --timeout=120s >/dev/null
}
finish_load() { # name -> prints "<total> <non200>"
  kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$1" --timeout=$((LOAD_SECONDS + 120))s >/dev/null
  local out; out="$(kubectl -n "$NS" logs "$1")"
  kubectl -n "$NS" delete pod "$1" --wait=false >/dev/null
  echo "$(echo "$out" | grep -c .) $(echo "$out" | grep -vc '^200$' || true)"
}
# kubectl port-forward binds to one pod chosen at start; re-establish it after rollouts replace pods
PF_PID=""
port_forward() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  kubectl -n "$NS" port-forward svc/frontend 18000:80 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 4
}
trap '[ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true' EXIT

assert_no_errors() { # label "<total> <errors>"
  set -- "$1" $2
  [ "$2" -gt 100 ] || fail "$1: too few requests measured ($2)"
  [ "$3" -eq 0 ] || fail "$1: $3 of $2 requests failed"
  ok "$1: $2 requests, 0 failed"
}

echo "== 0. Fixtures: namespace, test database, connection secret"
kubectl apply -f "$REPO_ROOT/k8s/namespace.yaml" >/dev/null
kubectl apply -f "$REPO_ROOT/k8s/testing/mysql-test-fixture.yaml" >/dev/null 2>&1 || true
if ! kubectl -n oi-testdb get secret mysql-test-credentials >/dev/null 2>&1; then
  APP_PW="$(node -e 'console.log(require("crypto").randomBytes(18).toString("hex"))')"
  ROOT_PW="$(node -e 'console.log(require("crypto").randomBytes(18).toString("hex"))')"
  kubectl -n oi-testdb create secret generic mysql-test-credentials \
    --from-literal=MYSQL_PASSWORD="$APP_PW" --from-literal=MYSQL_ROOT_PASSWORD="$ROOT_PW" >/dev/null
fi
kubectl apply -f "$REPO_ROOT/k8s/testing/mysql-test-fixture.yaml" >/dev/null
kubectl -n oi-testdb rollout status deploy/mysql --timeout=5m >/dev/null
APP_PW="$(kubectl -n oi-testdb get secret mysql-test-credentials -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)"
DB_HOST=mysql.oi-testdb.svc.cluster.local DB_USER=inventory DB_PASSWORD="$APP_PW" \
  "$REPO_ROOT/scripts/create-db-secret.sh" >/dev/null
# create-db-secret.sh requires TLS (as RDS does); the MySQL 8.4 image serves TLS by default.
ok "fixtures ready (test DB on a persistent volume, secret generated at run time)"

echo "== 1. Initial deployment (v1)"
deploy v1 >/dev/null || fail "initial deployment failed"
[ "$(image_tag backend)" = v1 ] && [ "$(image_tag frontend)" = v1 ] || fail "v1 not running"
port_forward
"$REPO_ROOT/scripts/smoke-test.sh" http://localhost:18000 >/dev/null || fail "smoke test failed on v1"
ok "v1 deployed, 20-check smoke test passed"

echo "== 2. Rolling update v1 -> v2 under load"
start_load load-update
deploy v2 >/dev/null || fail "v2 deployment failed"
[ "$(image_tag backend)" = v2 ] || fail "backend not on v2"
assert_no_errors "rolling update v1->v2" "$(finish_load load-update)"

echo "== 3. Bad image release"
start_load load-badimage
set +e; ROLLOUT_TIMEOUT=60s deploy does-not-exist >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || fail "deploying a non-existent image should fail"
[ "$(image_tag backend)" = v2 ] && [ "$(image_tag frontend)" = v2 ] || fail "not rolled back to v2 after bad image"
ok "bad image detected (exit $rc) and rolled back to v2"
assert_no_errors "bad image release + rollback" "$(finish_load load-badimage)"

echo "== 4. Failing readiness (new pods can never reach the database)"
kubectl -n "$NS" create secret generic mysql-secret-broken \
  --from-literal=url="jdbc:mysql://mysql.oi-testdb.svc.cluster.local:3306/order_inventory_db?sslMode=REQUIRED" \
  --from-literal=username=inventory --from-literal=password=wrong-password \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
start_load load-unhealthy
set +e; ROLLOUT_TIMEOUT=90s deploy v1 --set database.existingSecret=mysql-secret-broken >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || fail "a release whose pods never become Ready should fail"
[ "$(image_tag backend)" = v2 ] || fail "not rolled back to v2 after failing readiness"
[ "$(kubectl -n "$NS" get deploy backend -o jsonpath='{.spec.template.spec.containers[0].env[0].valueFrom.secretKeyRef.name}')" = mysql-secret ] \
  || fail "rollback did not restore the working database secret"
ok "unhealthy release detected (exit $rc) and rolled back"
assert_no_errors "unhealthy release + rollback" "$(finish_load load-unhealthy)"
kubectl -n "$NS" delete secret mysql-secret-broken >/dev/null

echo "== 5. Database outage"
BEFORE_RESTARTS="$(restarts)"
kubectl -n oi-testdb scale deploy/mysql --replicas=0 >/dev/null
for i in $(seq 1 30); do [ "$(ready_backends)" = 0 ] && break; sleep 2; done
[ "$(ready_backends)" = 0 ] || fail "backend pods should become unready while the database is down"
sleep 20
[ "$(restarts)" = "$BEFORE_RESTARTS" ] || fail "backend pods restarted during the outage ($BEFORE_RESTARTS -> $(restarts))"
ok "outage: all backend pods removed from service, 0 restarts"
kubectl -n oi-testdb scale deploy/mysql --replicas=1 >/dev/null
kubectl -n oi-testdb rollout status deploy/mysql --timeout=5m >/dev/null
for i in $(seq 1 60); do [ "$(ready_backends)" = 2 ] && break; sleep 3; done
[ "$(ready_backends)" = 2 ] || fail "backend pods did not recover after the database returned"
port_forward
SMOKE_READ_ONLY=1 "$REPO_ROOT/scripts/smoke-test.sh" http://localhost:18000 >/dev/null || fail "API not serving after recovery"
ok "database restored: pods Ready again and API serving (data persisted on PVC)"

echo "== 6. Pod loss"
VICTIM="$(kubectl -n "$NS" get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NS" delete pod "$VICTIM" --wait=false >/dev/null
sleep 3
kubectl -n "$NS" rollout status deploy/backend --timeout=3m >/dev/null
for i in $(seq 1 40); do [ "$(ready_backends)" = 2 ] && break; sleep 3; done
[ "$(ready_backends)" = 2 ] || fail "replacement pod did not become Ready"
ok "deleted pod $VICTIM replaced; 2/2 backend pods Ready"

echo "Helm history:"
helm -n "$NS" history order-inventory --max 10 | cut -c1-110
echo "All $PASS acceptance checks passed"
