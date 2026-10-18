#!/usr/bin/env bash
# Zero-downtime and rollback test against the REAL deployment on EKS, measured through the public ALB.
# A client on this machine requests GET /api/products and GET / continuously while each scenario runs;
# every response code is recorded. Scenarios:
#   A. rolling release GOOD -> ALT          B. rolling release ALT -> GOOD
#   C. release with a non-existent image (must fail, exit 1, auto-rollback)
#   D. release whose pods never become Ready (wrong DB credentials; must fail and roll back)
#   E. controlled restart of both deployments
# Old pods keep serving throughout (maxUnavailable 0), so C/D do not affect users.
#
#   ./scripts/aws-zero-downtime-test.sh <alb-url> <registry> <good-tag> <alt-tag>
set -uo pipefail

URL="${1:?alb url}"; REG="${2:?registry}"; GOOD="${3:?good tag}"; ALT="${4:?alt tag}"
URL="${URL%/}"
NS=order-inventory
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT_DIR:-$REPO_ROOT/.deploy/zdt}"; mkdir -p "$OUT"
FAILED=0

load_start() { # $1 = name
  rm -f "$OUT/$1.codes" "$OUT/stop"
  ( while [ ! -f "$OUT/stop" ]; do
      curl -s -o /dev/null -m 10 -w '%{http_code}\n' "$URL/api/products"
      curl -s -o /dev/null -m 10 -w '%{http_code}\n' "$URL/"
    done > "$OUT/$1.codes" ) &
  LOAD_PID=$!
  sleep 5
}
load_stop() { # $1 = name; settle so old pods finish draining before we stop measuring
  sleep "${SETTLE_SECONDS:-45}"
  touch "$OUT/stop"; wait "$LOAD_PID" 2>/dev/null
  local total fail dist
  total=$(grep -c . "$OUT/$1.codes"); fail=$(grep -vc '^200$' "$OUT/$1.codes")
  dist=$(sort "$OUT/$1.codes" | uniq -c | awk '{printf "%s×%s ", $1, $2}')
  echo "   requests: $total, non-200: $fail, status distribution: $dist"
  [ "$total" -gt 50 ] || { echo "   FAIL: too few requests measured"; FAILED=1; }
  [ "$fail" -eq 0 ] || FAILED=1
}
tags() { kubectl -n $NS get deploy backend frontend -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{" "}{end}' | sed "s#$REG/order-inventory-##g"; }
deploy() { local t0=$SECONDS; "$REPO_ROOT/scripts/deploy-k8s.sh" "$REG" "$@" > "$OUT/deploy.log" 2>&1; local rc=$?; echo "   deploy exit code: $rc, duration: $((SECONDS - t0))s, now running: $(tags)"; return $rc; }

echo "Target: $URL   start: $(tags)"

echo "== A. rolling release $GOOD -> $ALT"
load_start A; deploy "$ALT" || FAILED=1; load_stop A

echo "== B. rolling release $ALT -> $GOOD"
load_start B; deploy "$GOOD" || FAILED=1; load_stop B

echo "== C. release with a non-existent image (expect failure + automatic rollback)"
load_start C; ROLLOUT_TIMEOUT=120s deploy "does-not-exist-$RANDOM" && { echo "   FAIL: bad release was accepted"; FAILED=1; }; load_stop C
case "$(tags)" in *"backend:$GOOD"*"frontend:$GOOD"*) echo "   rolled back to $GOOD";; *) echo "   FAIL: not on $GOOD after rollback"; FAILED=1;; esac

echo "== D. release whose pods never become Ready (wrong DB credentials)"
kubectl -n $NS create secret generic mysql-secret-broken \
  --from-literal=url="$(kubectl -n $NS get secret mysql-secret -o jsonpath='{.data.url}' | base64 -d)" \
  --from-literal=username=admin --from-literal=password="intentionally-wrong-$RANDOM" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
load_start D; ROLLOUT_TIMEOUT=150s deploy "$ALT" --set database.existingSecret=mysql-secret-broken && { echo "   FAIL: unhealthy release was accepted"; FAILED=1; }; load_stop D
case "$(tags)" in *"backend:$GOOD"*) echo "   rolled back to $GOOD";; *) echo "   FAIL: not on $GOOD after rollback"; FAILED=1;; esac
[ "$(kubectl -n $NS get deploy backend -o jsonpath='{.spec.template.spec.containers[0].env[0].valueFrom.secretKeyRef.name}')" = mysql-secret ] \
  && echo "   working database secret restored" || { echo "   FAIL: broken secret still referenced"; FAILED=1; }
kubectl -n $NS delete secret mysql-secret-broken >/dev/null

echo "== E. controlled restart of both deployments"
load_start E; t0=$SECONDS
kubectl -n $NS rollout restart deploy/backend deploy/frontend >/dev/null
kubectl -n $NS rollout status deploy/backend --timeout=5m >/dev/null && kubectl -n $NS rollout status deploy/frontend --timeout=5m >/dev/null
echo "   restart completed in $((SECONDS - t0))s"; load_stop E

echo "== Post-test health"
SMOKE_READ_ONLY=1 "$REPO_ROOT/scripts/smoke-test.sh" "$URL" | tail -1 || FAILED=1
echo "Helm history:"; helm -n $NS history order-inventory --max 12 | cut -c1-120
[ "$FAILED" -eq 0 ] && echo "RESULT: all scenarios passed" || { echo "RESULT: FAILURES detected"; exit 1; }
