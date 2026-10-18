#!/usr/bin/env bash
# End-to-end smoke test against a running deployment.
#   ./scripts/smoke-test.sh http://localhost:3000          # Docker Compose (via frontend nginx)
#   ./scripts/smoke-test.sh http://<alb-dns-name>          # EKS (via ALB Ingress)
#
# Creates a uniquely-named user, product and order (and cancels the order, restoring stock),
# so it is safe to run repeatedly against a shared environment. Exits non-zero on the first failure.
# SMOKE_READ_ONLY=1 limits the run to GET checks (used by the CI/CD post-deploy verification so
# production deployments do not create test records).
set -euo pipefail

BASE_URL="${1:-http://localhost:3000}"
BASE_URL="${BASE_URL%/}"
RUN_ID="smoke-$(date +%s)-$RANDOM"
PASS=0

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "ok   - $*"; }

# request METHOD PATH [JSON_BODY] -> sets STATUS and BODY
request() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -o /tmp/smoke_body.$$ -w '%{http_code}' -X "$method" -H 'Accept: application/json' --max-time 15)
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' --data "$data")
  STATUS=$(curl "${args[@]}" "$BASE_URL$path") || fail "$method $path: connection error"
  BODY=$(cat /tmp/smoke_body.$$)
}
expect() { [ "$STATUS" = "$1" ] || fail "$2 (expected HTTP $1, got $STATUS: $BODY)"; ok "$2 -> $STATUS"; }
json() { node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const v=eval("JSON.parse(d)"+process.argv[1]);console.log(v)})' "$1" <<<"$BODY"; }

trap 'rm -f /tmp/smoke_body.$$' EXIT
echo "Smoke testing $BASE_URL (run $RUN_ID)"

# --- Frontend + health -------------------------------------------------------
request GET /                      ; expect 200 "frontend index served"
echo "$BODY" | grep -q '<div id="root">' || fail "index.html does not contain the React root"
request GET /products              ; expect 200 "SPA deep link served by fallback"
request GET /api/health            ; expect 200 "liveness /api/health"
[ "$(json .status)" = "UP" ] || fail "health status not UP"
request GET /api/health/ready      ; expect 200 "readiness /api/health/ready (database reachable)"
[ "$(json .database)" = "UP" ] || fail "database not UP"

if [ "${SMOKE_READ_ONLY:-0}" = "1" ]; then
  request GET /api/products ; expect 200 "list products (read-only mode)"
  request GET /api/users    ; expect 200 "list users (read-only mode)"
  request GET /api/orders   ; expect 200 "list orders (read-only mode)"
  request GET /api/no-such-endpoint ; expect 404 "unknown API route"
  echo "All $PASS read-only checks passed against $BASE_URL"
  exit 0
fi

# --- Users -------------------------------------------------------------------
request POST /api/users "{\"name\":\"Smoke Test\",\"email\":\"$RUN_ID@Example.com\"}"
expect 201 "create user"
USER_ID=$(json .id)
request POST /api/users "{\"name\":\"Dup\",\"email\":\"$RUN_ID@example.com\"}"
expect 400 "duplicate email rejected (case-insensitive)"
request GET "/api/users/$USER_ID"  ; expect 200 "get user"

# --- Products ----------------------------------------------------------------
request POST /api/products "{\"name\":\"$RUN_ID widget\",\"price\":12.50,\"stockQuantity\":5,\"category\":\"Smoke\"}"
expect 201 "create product"
PRODUCT_ID=$(json .id)
[ "$(json .status)" = "LOW_STOCK" ] || fail "expected LOW_STOCK status"
request PUT "/api/products/$PRODUCT_ID" "{\"name\":\"$RUN_ID widget\",\"price\":12.50,\"stockQuantity\":20,\"category\":\"Smoke\"}"
expect 200 "update product"
request POST /api/products '{"name":"","price":0,"stockQuantity":-1}'
expect 400 "invalid product rejected"

# --- Orders (stock reservation + cancellation) -------------------------------
request POST /api/orders "{\"userId\":$USER_ID,\"items\":[{\"productId\":$PRODUCT_ID,\"quantity\":3}]}"
expect 201 "create order"
ORDER_ID=$(json .id)
[ "$(json .totalAmount)" = "37.5" ] || fail "unexpected order total $(json .totalAmount)"
request GET "/api/products/$PRODUCT_ID"; [ "$(json .stockQuantity)" = "17" ] || fail "stock not deducted"; ok "stock deducted to 17"
request POST /api/orders "{\"userId\":$USER_ID,\"items\":[{\"productId\":$PRODUCT_ID,\"quantity\":999}]}"
expect 400 "order exceeding stock rejected"
request PUT "/api/orders/$ORDER_ID/status" '{"status":"CANCELLED"}'
expect 200 "cancel order"
request GET "/api/products/$PRODUCT_ID"; [ "$(json .stockQuantity)" = "20" ] || fail "stock not restored"; ok "stock restored to 20"
request PUT "/api/orders/$ORDER_ID/status" '{"status":"PENDING"}'
expect 400 "cancelled order cannot be reopened"
request DELETE "/api/products/$PRODUCT_ID"
expect 409 "product referenced by an order cannot be deleted"

# --- Error handling ----------------------------------------------------------
request GET /api/products/not-a-number ; expect 400 "non-numeric id"
request GET /api/orders/99999999       ; expect 404 "missing order"
request GET /api/no-such-endpoint      ; expect 404 "unknown API route"

echo "All $PASS checks passed against $BASE_URL"
