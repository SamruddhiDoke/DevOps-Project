#!/usr/bin/env bash
# Test the Jenkins playbook against a disposable Ubuntu 24.04 container running systemd
# (same OS as the Jenkins EC2 host). Runs: syntax check, ansible-lint, apply, idempotency
# (second run must report changed=0) and service health. The container is removed afterwards.
#   ./ansible/test/test-in-container.sh
set -euo pipefail

ANSIBLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAME=oi-ansible-test
IMAGE=geerlingguy/docker-ubuntu2404-ansible:latest
export MSYS_NO_PATHCONV=1

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --name "$NAME" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw "$IMAGE" /lib/systemd/systemd >/dev/null
# Minimized container images strip /usr/share/man; OpenJDK's post-install needs man1 (present on EC2 Ubuntu)
docker exec "$NAME" sh -c 'mkdir -p /project /usr/share/man/man1'
SRC="$ANSIBLE_DIR"; command -v cygpath >/dev/null && SRC="$(cygpath -w "$ANSIBLE_DIR")"
docker cp "$SRC/." "$NAME:/project/"
docker exec "$NAME" sh -c 'printf "[jenkins]\nlocalhost ansible_connection=local\n" > /project/inventory.ini'

run() { docker exec -w /project -e ANSIBLE_FORCE_COLOR=0 "$NAME" sh -c "$*"; }

echo "== ansible version"; run 'ansible --version | head -1'
echo "== syntax check";    run 'ansible-playbook playbooks/jenkins.yml --syntax-check'
echo "== ansible-lint"
# Isolated virtualenv: pip cannot upgrade Debian-managed packages in place
run 'command -v python3 >/dev/null; apt-get -qq update >/dev/null && apt-get -qq install -y python3-venv >/dev/null; python3 -m venv /opt/lint && /opt/lint/bin/pip install --quiet ansible-lint'
run '/opt/lint/bin/ansible-lint --offline playbooks/jenkins.yml'

# Docker-in-Docker inside a test container is not representative; the daemon is started on EC2.
echo "== apply (first run)"
run 'ansible-playbook playbooks/jenkins.yml -e docker_start_service=false' | tee /tmp/ansible-run1.log | tail -25
grep -qE 'failed=0' /tmp/ansible-run1.log || { echo "FAIL: first run had failures"; exit 1; }

echo "== idempotency (second run must change nothing)"
run 'ansible-playbook playbooks/jenkins.yml -e docker_start_service=false' | tee /tmp/ansible-run2.log | grep -E 'PLAY RECAP' -A2
grep -qE 'changed=0 .*failed=0' /tmp/ansible-run2.log || { echo "FAIL: second run was not idempotent"; grep -E 'changed:' /tmp/ansible-run2.log; exit 1; }

echo "== service health"
run 'systemctl is-active jenkins && curl -s -o /dev/null -w "jenkins /login HTTP %{http_code}\n" http://127.0.0.1:8080/login'
echo "Ansible test passed"
