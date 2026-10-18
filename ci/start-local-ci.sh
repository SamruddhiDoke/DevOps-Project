#!/usr/bin/env bash
# Start the local CI environment (SonarQube + Jenkins) with generated credentials.
# Secrets are written only to ci/.env (git-ignored) and never printed.
#   ./ci/start-local-ci.sh
set -euo pipefail

CI_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$CI_DIR/.env"
SONAR_URL="http://127.0.0.1:19000"
dc() { docker compose -f "$CI_DIR/docker-compose.ci.yml" "$@"; }
rand() { node -e 'const c=require("crypto");console.log(c.randomBytes(18).toString("base64url")+"Aa1!")'; }
env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true; }
env_set() { touch "$ENV_FILE"; grep -vE "^$1=" "$ENV_FILE" > "$ENV_FILE.tmp" || true; echo "$1=$2" >> "$ENV_FILE.tmp"; mv "$ENV_FILE.tmp" "$ENV_FILE"; }

[ -n "$(env_get JENKINS_ADMIN_PASSWORD)" ] || env_set JENKINS_ADMIN_PASSWORD "$(rand)"
# Group that owns the Docker socket inside the Docker VM (lets the jenkins user run docker builds)
env_set DOCKER_SOCKET_GID "$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock alpine:3 stat -c %g /var/run/docker.sock)"

echo "Starting SonarQube..."
dc up -d sonarqube >/dev/null
for i in $(seq 1 90); do
  curl -sf "$SONAR_URL/api/system/status" | grep -q '"status":"UP"' && break
  sleep 5
done
curl -sf "$SONAR_URL/api/system/status" | grep -q '"status":"UP"' || { echo "SonarQube did not start" >&2; exit 1; }

# Replace the default admin/admin password on first start
if [ -z "$(env_get SONAR_ADMIN_PASSWORD)" ]; then
  NEW_PW="$(rand)"
  curl -sf -u admin:admin -X POST "$SONAR_URL/api/users/change_password" \
    --data-urlencode login=admin --data-urlencode previousPassword=admin --data-urlencode "password=$NEW_PW" \
    || { echo "Could not change the SonarQube admin password (already changed? set SONAR_ADMIN_PASSWORD in ci/.env)" >&2; exit 1; }
  env_set SONAR_ADMIN_PASSWORD "$NEW_PW"
fi

# Analysis token for Jenkins
if [ -z "$(env_get SONAR_TOKEN)" ]; then
  TOKEN="$(curl -sf -u "admin:$(env_get SONAR_ADMIN_PASSWORD)" -X POST "$SONAR_URL/api/user_tokens/generate" \
    --data-urlencode "name=jenkins-$(date +%s)" --data-urlencode type=GLOBAL_ANALYSIS_TOKEN | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).token||""))')"
  [ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "Could not create a SonarQube token" >&2; exit 1; }
  env_set SONAR_TOKEN "$TOKEN"
fi

echo "Building and starting Jenkins..."
dc up -d --build jenkins >/dev/null
for i in $(seq 1 60); do
  curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18090/login | grep -q 200 && break
  sleep 5
done
echo "Jenkins:   http://localhost:18090  (user admin, password: JENKINS_ADMIN_PASSWORD in ci/.env)"
echo "SonarQube: http://localhost:19000  (user admin, password: SONAR_ADMIN_PASSWORD in ci/.env)"
