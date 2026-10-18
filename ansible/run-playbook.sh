#!/usr/bin/env bash
# Run the Jenkins playbook against the EC2 host from any machine with Docker (no local Ansible
# needed). Host IP comes from Terraform outputs; admin passwords come from Secrets Manager and are
# streamed into the controller container on stdin (never in arguments, files in the repo, or logs).
#
#   SSH_KEY=~/Downloads/UniversalKey.pem ./ansible/run-playbook.sh            # apply
#   SSH_KEY=... ./ansible/run-playbook.sh --check                             # dry run
#
# Env: SSH_KEY (required), JENKINS_REPO_URL (default: local mirror on the host while GitHub carries
#      the pre-remediation history), AWS_PROFILE/AWS_REGION for the AWS CLI.
set -euo pipefail

ANSIBLE_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$ANSIBLE_DIR/../terraform"
: "${SSH_KEY:?Set SSH_KEY to the private key of the EC2 key pair}"
export MSYS_NO_PATHCONV=1

HOST="$(terraform -chdir="$TF_DIR" output -raw jenkins_public_ip)"
BUCKET="$(terraform -chdir="$TF_DIR" output -raw ci_reports_bucket)"
REPO_URL="${JENKINS_REPO_URL:-file:///srv/git/devops-project.git}"
LOCAL_CHECKOUT=false; case "$REPO_URL" in file://*) LOCAL_CHECKOUT=true ;; esac

secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text | tr -d '\r'; }

win() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }

# Extra vars (secrets included) are streamed on stdin as JSON
node -e '
  const [jp, sp, url, local, bucket] = process.argv.slice(1);
  process.stdout.write(JSON.stringify({
    jenkins_casc_admin_password: jp,
    sonarqube_admin_password: sp,
    jenkins_casc_repo_url: url,
    jenkins_casc_allow_local_checkout: local === "true",
    jenkins_casc_ci_reports_bucket: bucket,
    jenkins_casc_sonar_host_url: "http://127.0.0.1:9000"
  }));' "$(secret order-inventory/jenkins-admin)" "$(secret order-inventory/sonarqube-admin)" "$REPO_URL" "$LOCAL_CHECKOUT" "$BUCKET" \
| docker run --rm -i \
    -v "$(win "$ANSIBLE_DIR")":/ansible:ro \
    -v "$(win "$SSH_KEY")":/tmp/key.pem:ro \
    -e ANSIBLE_HOST_KEY_CHECKING=False -e ANSIBLE_FORCE_COLOR=0 \
    python:3.12-slim sh -c '
      set -e
      cat > /tmp/extra-vars.json
      apt-get -qq update >/dev/null && apt-get -qq install -y openssh-client >/dev/null
      pip install --quiet --disable-pip-version-check ansible-core==2.19.* >/dev/null
      ansible-galaxy collection install --upgrade -r /ansible/requirements.yml >/dev/null
      install -m 600 /tmp/key.pem /tmp/id
      printf "[jenkins]\njenkins-server ansible_host='"$HOST"' ansible_user=ubuntu ansible_ssh_private_key_file=/tmp/id\n" > /tmp/inventory.ini
      cd /ansible
      ANSIBLE_CONFIG=/ansible/ansible.cfg ansible-playbook -i /tmp/inventory.ini playbooks/jenkins.yml -e @/tmp/extra-vars.json '"$*"'
    '
