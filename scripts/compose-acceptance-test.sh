#!/usr/bin/env bash
# Docker Compose acceptance test: build -> start -> functional smoke test -> persistence across
# recreation -> database outage + recovery -> crash auto-restart -> clean shutdown (volume kept).
#
#   ./scripts/compose-acceptance-test.sh                 # uses the default Compose project
#   COMPOSE_PROJECT_NAME=oi-fresh ./scripts/compose-acceptance-test.sh   # isolated project/volume
#
# Host ports come from the environment / .env (FRONTEND_HOST_PORT, BACKEND_HOST_PORT, MYSQL_HOST_PORT).
# The script never deletes volumes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/order-inventory-platform"
FRONTEND_URL="http://localhost:${FRONTEND_HOST_PORT:-3000}"
PASS=0

cd "$APP_DIR"
dc() { docker compose "$@"; }
ok()   { PASS=$((PASS + 1)); echo "ok   - $*"; }
fail() { echo "FAIL: $*" >&2; dc ps >&2 || true; dc logs --tail=40 backend >&2 || true; exit 1; }

# Container names are fixed in docker-compose.yml; resolve the backend/mysql ids per project
cid() { dc ps -q "$1"; }

wait_healthy() { # service timeout_seconds
  local svc="$1" deadline=$(( $(date +%s) + ${2:-180} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$(cid "$svc")" 2>/dev/null)" = "healthy" ] && return 0
    sleep 3
  done
  fail "$svc did not become healthy within ${2:-180}s"
}
http_code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$1" || true; }
user_count() { curl -sf -m 10 "$FRONTEND_URL/api/users" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).length))'; }

echo "== Build and start (project: ${COMPOSE_PROJECT_NAME:-default})"
dc up -d --build >/dev/null
for s in mysql backend frontend; do wait_healthy "$s" 300; done
ok "all services healthy"

[ "$(http_code "$FRONTEND_URL/")" = "200" ] || fail "frontend not reachable"
ok "frontend reachable at $FRONTEND_URL"

echo "== Functional smoke test"
"$REPO_ROOT/scripts/smoke-test.sh" "$FRONTEND_URL" | tail -1
ok "smoke test passed"

echo "== Persistence across container recreation"
BEFORE=$(user_count)
dc down >/dev/null            # removes containers and network, keeps the named volume
dc up -d >/dev/null
for s in mysql backend frontend; do wait_healthy "$s" 300; done
AFTER=$(user_count)
[ "$BEFORE" = "$AFTER" ] || fail "user count changed across recreation ($BEFORE -> $AFTER)"
ok "data persisted across down/up ($AFTER users)"

echo "== Database outage and recovery"
dc stop mysql >/dev/null
sleep 8
[ "$(http_code "$FRONTEND_URL/api/health/ready")" = "503" ] || fail "readiness should be 503 while MySQL is down"
[ "$(http_code "$FRONTEND_URL/api/products")" = "503" ] || fail "API should return 503 while MySQL is down"
[ "$(http_code "$FRONTEND_URL/api/health")" = "200" ] || fail "liveness should stay 200 while MySQL is down"
ok "outage: readiness 503, API 503, liveness 200"
dc start mysql >/dev/null
wait_healthy mysql 180
deadline=$(( $(date +%s) + 90 ))
until [ "$(http_code "$FRONTEND_URL/api/products")" = "200" ]; do
  [ "$(date +%s)" -lt "$deadline" ] || fail "API did not recover after MySQL restart"
  sleep 3
done
ok "API recovered automatically after MySQL restart"

echo "== Crash auto-restart (restart: unless-stopped)"
# Terminate the JVM from inside the container to simulate a crash. (`docker kill`/`docker stop`
# count as manual stops, after which Docker intentionally does not apply the restart policy.)
RESTARTS_BEFORE=$(docker inspect -f "{{.RestartCount}}" "$(cid backend)")
docker exec "$(cid backend)" sh -c "kill -TERM 1" || true
sleep 5
wait_healthy backend 180
RESTARTS_AFTER=$(docker inspect -f "{{.RestartCount}}" "$(cid backend)")
[ "$RESTARTS_AFTER" -gt "$RESTARTS_BEFORE" ] || fail "backend was not restarted by Docker (restart count $RESTARTS_BEFORE -> $RESTARTS_AFTER)"
ok "backend process exited and Docker restarted it automatically (restart count $RESTARTS_BEFORE -> $RESTARTS_AFTER)"

echo "== Clean shutdown (volume kept)"
dc stop >/dev/null
ok "stack stopped; data volume retained"

echo "All $PASS acceptance checks passed"
