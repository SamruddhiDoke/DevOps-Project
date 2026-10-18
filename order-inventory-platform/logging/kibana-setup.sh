#!/usr/bin/env bash
# Import the Kibana data view, saved searches and the "Order Inventory - Operations" dashboard.
# Idempotent (overwrites the same object ids).
#   ./order-inventory-platform/logging/kibana-setup.sh [http://localhost:5601]
set -euo pipefail

KIBANA="${1:-http://localhost:5601}"
DIR="$(cd "$(dirname "$0")" && pwd)"
FILE="$DIR/kibana-saved-objects.ndjson"
command -v cygpath >/dev/null && FILE="$(cygpath -w "$FILE")"

for i in $(seq 1 60); do
  curl -sf "$KIBANA/api/status" | grep -q '"level":"available"' && break
  sleep 5
done

curl -sf -X POST "$KIBANA/api/saved_objects/_import?overwrite=true" \
  -H 'kbn-xsrf: true' --form "file=@$FILE" \
  | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const r=JSON.parse(d);console.log(`imported ${r.successCount} objects, success=${r.success}`);if(!r.success){console.error(JSON.stringify(r.errors));process.exit(1)}})'
echo "Dashboard: $KIBANA/app/dashboards#/view/oi-operations"
