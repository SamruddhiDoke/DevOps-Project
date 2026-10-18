#!/usr/bin/env bash
# Create/update the Kubernetes Secret the backend reads its database connection from.
# The password is read from TF_VAR_db_password (the same value given to Terraform) or prompted for;
# it is never written to disk or echoed.
#
#   export TF_VAR_db_password=...          # optional; prompted if unset
#   ./scripts/create-db-secret.sh          # reads the RDS endpoint from terraform output
#   DB_HOST=mysql.example ./scripts/create-db-secret.sh   # or provide the host explicitly
set -euo pipefail

NAMESPACE="${K8S_NAMESPACE:-order-inventory}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DB_HOST="${DB_HOST:-$(terraform -chdir="$REPO_ROOT/terraform" output -raw rds_endpoint)}"
DB_USER="${DB_USER:-admin}"
DB_PASSWORD="${TF_VAR_db_password:-}"
if [ -z "$DB_PASSWORD" ]; then
  read -r -s -p "Database password for ${DB_USER}: " DB_PASSWORD
  echo
fi

# RDS enforces TLS-capable connections; require it in transit inside the VPC as well
DB_URL="jdbc:mysql://${DB_HOST}:3306/order_inventory_db?sslMode=REQUIRED&serverTimezone=UTC"

kubectl create secret generic mysql-secret \
  --namespace "$NAMESPACE" \
  --from-literal=url="$DB_URL" \
  --from-literal=username="$DB_USER" \
  --from-literal=password="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret mysql-secret applied in namespace ${NAMESPACE} (host: ${DB_HOST})"
