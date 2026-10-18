#!/usr/bin/env bash
# Create/update the Kubernetes Secret the backend reads its database connection from.
#
# AWS (default): credentials come from the Secrets Manager secret created by Terraform
# (terraform output db_secret_arn); they are piped straight into kubectl and never printed.
#   ./scripts/create-db-secret.sh
#
# Other clusters (e.g. the minikube acceptance test): provide the values explicitly.
#   DB_HOST=mysql.example DB_USER=inventory DB_PASSWORD=... ./scripts/create-db-secret.sh
set -euo pipefail

NAMESPACE="${K8S_NAMESPACE:-order-inventory}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${DB_PASSWORD:-}" ]; then
  SECRET_ARN="${DB_SECRET_ARN:-$(terraform -chdir="$REPO_ROOT/terraform" output -raw db_secret_arn)}"
  SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text)"
  field() { node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>process.stdout.write(String(JSON.parse(d)[process.argv[1]])))' "$1" <<<"$SECRET_JSON"; }
  DB_HOST="$(field host)"
  DB_USER="$(field username)"
  DB_PASSWORD="$(field password)"
  unset SECRET_JSON
fi
: "${DB_HOST:?DB_HOST is required}"
DB_USER="${DB_USER:-admin}"

# TLS required in transit (RDS enforces require_secure_transport)
DB_URL="jdbc:mysql://${DB_HOST}:3306/order_inventory_db?sslMode=REQUIRED&serverTimezone=UTC"

kubectl create secret generic mysql-secret \
  --namespace "$NAMESPACE" \
  --from-literal=url="$DB_URL" \
  --from-literal=username="$DB_USER" \
  --from-literal=password="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset DB_PASSWORD

echo "Secret mysql-secret applied in namespace ${NAMESPACE} (host: ${DB_HOST})"
