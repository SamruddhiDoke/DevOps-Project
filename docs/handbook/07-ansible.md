# Part 10 — Ansible

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md) · Files in `ansible/`.

## 7.1 Terraform vs Ansible in this project

| | Terraform | Ansible |
|---|---|---|
| Works on | AWS APIs | the operating system of a host over SSH |
| Creates | the Jenkins EC2 instance, its security group, IAM role, generated admin passwords | packages, users, services, files and containers **inside** that instance |
| Model | declarative desired state + state file | ordered tasks, each idempotent (check, then change only if needed) |
| Here | `terraform/jenkins.tf` | `ansible/playbooks/jenkins.yml` + 7 roles |

Terraform's comment in `jenkins.tf` states the split: "Terraform creates the instance, network access and IAM
permissions only. Software … is installed and kept up to date by Ansible". Ansible is **not** used for
application deployments: the application is deployed by Jenkins with Helm (`scripts/deploy-k8s.sh`), because
Kubernetes provides rolling updates, health checks and rollback that a host-level tool would have to
reimplement.

## 7.2 Running it: `run-playbook.sh` (line by line)

```bash
win() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }
ANSIBLE_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$(win "$(cd "$ANSIBLE_DIR/../terraform" && pwd)")"
: "${SSH_KEY:?Set SSH_KEY to the private key of the EC2 key pair}"
export MSYS_NO_PATHCONV=1
```
Windows/Git Bash helpers: `cygpath -w` converts `/c/...` paths for the Windows `terraform.exe` and Docker;
`MSYS_NO_PATHCONV=1` stops Git Bash from rewriting Linux paths like `/ansible` in `docker run` arguments. The
script requires `SSH_KEY` (path to `UniversalKey.pem`).

```bash
HOST="$(terraform -chdir="$TF_DIR" output -raw jenkins_public_ip)"
BUCKET="$(terraform -chdir="$TF_DIR" output -raw ci_reports_bucket)"
REPO_URL="${JENKINS_REPO_URL:-file:///srv/git/devops-project.git}"
LOCAL_CHECKOUT=false; case "$REPO_URL" in file://*) LOCAL_CHECKOUT=true ;; esac
```
Target host and bucket from Terraform outputs. **Important trap:** the default `REPO_URL` is still the old
on-host Git mirror (used while GitHub had the uncleaned history). Since 2026-10-19 the job must use GitHub, so
**always** run it as:

```bash
export AWS_PROFILE=order-inventory AWS_REGION=ap-south-1
terraform -chdir=terraform apply -refresh-only -var-file=environments/full.tfvars -var-file=admin.auto.tfvars   # update jenkins_public_ip after a stop/start (state only)
SSH_KEY=/c/Users/Siddesh/Downloads/UniversalKey.pem \
JENKINS_REPO_URL=https://github.com/SamruddhiDoke/DevOps-Project.git ./ansible/run-playbook.sh --check   # dry run
SSH_KEY=/c/Users/Siddesh/Downloads/UniversalKey.pem \
JENKINS_REPO_URL=https://github.com/SamruddhiDoke/DevOps-Project.git ./ansible/run-playbook.sh           # apply
```
Without `JENKINS_REPO_URL`, the job would be switched back to the (stale) mirror. Also: the jenkins_casc role
restarts Jenkins when configuration changes — a running build is then interrupted (that is exactly what made
build #6 fail on 2026-10-19), so do not run the playbook while a build is in progress.

```bash
secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text | tr -d '\r'; }
node -e '…process.stdout.write(JSON.stringify({ jenkins_casc_admin_password: jp, sonarqube_admin_password: sp,
   jenkins_casc_repo_url: url, jenkins_casc_allow_local_checkout: local === "true",
   jenkins_casc_ci_reports_bucket: bucket, jenkins_casc_sonar_host_url: "http://127.0.0.1:9000" }));' \
   "$(secret order-inventory/jenkins-admin)" "$(secret order-inventory/sonarqube-admin)" "$REPO_URL" "$LOCAL_CHECKOUT" "$BUCKET" \
| docker run --rm -i -v "$(win "$ANSIBLE_DIR")":/ansible:ro -v "$(win "$SSH_KEY")":/tmp/key.pem:ro \
    -e ANSIBLE_HOST_KEY_CHECKING=False -e ANSIBLE_FORCE_COLOR=0 python:3.12-slim sh -c '…'
```
- The two admin passwords are read from **Secrets Manager** and turned into a JSON document of Ansible extra
  variables, which is **piped on stdin** into a disposable `python:3.12-slim` container; inside, it is saved to
  `/tmp/extra-vars.json` (container-local, deleted with the container) and passed as `-e @/tmp/extra-vars.json`.
  So the secrets are not in the `docker run` arguments, the repository, files on the laptop or Ansible output.
- **Honest limitation:** on the laptop the secrets are passed to the local `node` process as command-line
  arguments (`"$(secret …)"`), so for the fraction of a second that `node` runs they are visible in the
  process list to other processes of the same Windows user. Reading them inside the `node` script (or piping
  the Secrets Manager JSON straight into the container) would remove that exposure. This was not changed
  while writing the handbook (working code is not modified for documentation).
- Inside the container: install `openssh-client`, `ansible-core==2.19.*`, the collections from
  `requirements.yml`; copy the key with mode 600; write a one-line inventory with the Jenkins IP; run
  `ansible-playbook -i /tmp/inventory.ini playbooks/jenkins.yml -e @/tmp/extra-vars.json "$@"` (so `--check`
  etc. are passed through). The repository is mounted **read-only**.
- `ANSIBLE_HOST_KEY_CHECKING=False` is set for this throwaway controller: the container starts with an empty
  `known_hosts` on every run, so it could never confirm the host key interactively. The trade-off is that the
  first connection is not protected against a man-in-the-middle; `ansible.cfg` keeps checking enabled for
  normal, persistent controllers.

## 7.3 Configuration files

| File | Lines and meaning |
|---|---|
| `ansible.cfg` | `inventory = inventory.ini` (local, git-ignored), `roles_path = roles`, `host_key_checking = True`, `retry_files_enabled = False`, `interpreter_python = auto_silent`; `[ssh_connection] pipelining = True` (fewer SSH round-trips) |
| `inventory.example.ini` | `[jenkins]` group with one host `jenkins-server ansible_host=… ansible_user=ubuntu ansible_ssh_private_key_file=…` (template; `run-playbook.sh` generates its own) |
| `group_vars/all.yml` | pinned versions: Maven 3.9.12, Node 24.22.0, Trivy 0.76.0, Helm 4.3.1, kubectl 1.36.5, Terraform 1.15.8, SonarScanner 8.1.0.6389; `jenkins_port: 8080`; `docker_start_service: true` (false only in the container test). Kept in sync with `ci/jenkins/Dockerfile` |
| `requirements.yml` | collections `community.docker` (container module), `ansible.posix` (sysctl), `community.general` (git_config) |

## 7.4 `playbooks/jenkins.yml` (line by line)

```yaml
- name: Configure Jenkins CI server
  hosts: jenkins                 # the inventory group
  become: true                   # privilege escalation: tasks run as root via sudo
  vars_files: [ ../group_vars/all.yml ]   # explicit, because run-playbook.sh's inventory lives in /tmp
  roles:
    - common
    - docker
    - build_tools
    - jenkins
    - role: git_mirror          ; when: jenkins_casc_allow_local_checkout | default(false) | bool
    - role: sonarqube           ; when: sonarqube_admin_password | default('') | length > 0
    - role: jenkins_casc        ; when: jenkins_casc_admin_password | default('') | length > 0
  post_tasks:  # print the first line of each tool's version (changed_when: false = never reports "changed")
```
Roles run in order; the last three are conditional so the playbook can also run without secrets (base
toolchain only). The post-task loop prints Java, Maven, Node, Trivy, Helm, kubectl, Terraform, SonarScanner,
AWS CLI and Docker versions (`set -o pipefail; … | sed -n 1p`; `sed` instead of `head` avoids a SIGPIPE
failure under `pipefail`).

## 7.5 Roles (task by task)

### `common`
1. `apt` installs base packages (`ca-certificates curl unzip xz-utils git jq fontconfig unattended-upgrades
   openssh-server python3-debian`), `cache_valid_time: 3600` (no apt update if done within an hour).
2. `copy` `/etc/apt/apt.conf.d/20auto-upgrades` → daily automatic **security updates**.
3. `file` ensures `/run/sshd` exists (needed by `sshd -t`; Ubuntu 24.04 starts sshd via socket activation).
4. `copy` `/etc/ssh/sshd_config.d/10-hardening.conf`: `PasswordAuthentication no`,
   `KbdInteractiveAuthentication no`, `PermitRootLogin no`, with `validate: /usr/sbin/sshd -t -f %s` — an
   invalid file is **rejected before it replaces the old one** (prevents locking yourself out); `notify:
   Reload ssh` → handler reloads the service only when the file changed.

### `docker`
`apt docker.io`; service started and enabled (`when: docker_start_service | bool`). Jenkins builds images
with this daemon.

### `build_tools`
- `openjdk-21-jdk-headless` (runs Jenkins; compiles the Java 17 backend).
- Maven, Node.js, SonarScanner: `unarchive` from the official URLs with `remote_src: true` and
  **`creates:`** pointing at the binary of that exact version → skipped when already installed (idempotent);
  a version change in `group_vars` installs the new version.
- Symlinks into `/usr/local/bin` (`mvn`, `node`, `npm`, `npx`, `sonar-scanner`).
- Single-binary tools: first a check task runs `trivy --version | grep -qF <version>` etc. with
  `failed_when: false`, `changed_when: false`; the install tasks for Trivy, Helm, kubectl (with `timeout: 120`,
  `retries: 3` because a download once timed out) and Terraform run **only when the check's `rc != 0`**.
- AWS CLI v2: check `/usr/local/bin/aws --version`; download + `/tmp/aws/install` only if missing
  (`creates: /usr/local/bin/aws`).

### `jenkins`
Add the Jenkins LTS apt repository in deb822 format with its signing key (`signed_by` pinned to
`jenkins.io-2026.key`), install `jenkins`, add the `jenkins` user to group `docker` (notify restart), create the
systemd drop-in directory, start + enable, `flush_handlers` (apply pending restarts now), wait until
`http://127.0.0.1:8080/login` returns 200 (30 × 10 s). Handler: `systemd_service` restart with
`daemon_reload`.

### `git_mirror` (historical)
Bare repository `/srv/git/devops-project.git` owned by the SSH user, plus `git config --system --add
safe.directory` for that path (fixes Git's "dubious ownership" error when the `jenkins` user reads it). Only
runs when `jenkins_casc_allow_local_checkout` is true (i.e. a `file://` URL). Not used since the job was switched
to GitHub.

### `sonarqube`
1. `assert` the admin password is ≥ 12 characters.
2. `sysctl` `vm.max_map_count=524288`, `fs.file-max=131072` (required by SonarQube's embedded Elasticsearch).
3. `python3-docker` (needed by the Docker module).
4. `community.docker.docker_container` `sonarqube:26.10.0.133078-community`, `restart_policy: unless-stopped`,
   published **only on `127.0.0.1:9000`** (not reachable from outside; admins use an SSH tunnel), named volumes
   for data/extensions/logs (persist on the EBS volume across stop/start), 512 MB heaps.
5. Wait until `/api/system/status` is `UP` (60 × 10 s).
6. Check whether the generated admin password already works (`/api/authentication/validate`, `no_log`);
   if not, change the factory default password to the generated one (`no_log`; the literal `admin` is
   SonarQube's documented default, marked `# gitleaks:allow`).
7. `/etc/jenkins-secrets` (root:jenkins 0750); if no token file exists, generate a `GLOBAL_ANALYSIS_TOKEN`
   and store it in `/etc/jenkins-secrets/sonar_token` (root:jenkins 0640, `no_log`), notify Jenkins restart.

### `jenkins_casc`
1. `assert` admin password length.
2. Download the Jenkins plugin installation manager (pinned 2.15.0); write `/var/lib/jenkins/plugins.txt`
   (workflow-aggregator, pipeline-model-definition, git, junit, timestamper, coverage,
   configuration-as-code, credentials-binding, job-dsl, matrix-auth); install plugins **only if the list
   changed** (resolves versions compatible with the installed Jenkins WAR), notify restart.
3. Render `templates/casc.yaml.j2` to `/var/lib/jenkins/casc.yaml` (0640).
4. Read the Sonar token (`slurp`, `failed_when: false`, `no_log`) and write
   `/etc/jenkins-secrets/jenkins.env` with `JENKINS_ADMIN_PASSWORD` and `SONAR_TOKEN` (root:jenkins 0640, `no_log`).
5. systemd override: `JAVA_OPTS` disables the setup wizard (and enables local checkout only for `file://`),
   `CASC_JENKINS_CONFIG=/var/lib/jenkins/casc.yaml`, `EnvironmentFile=/etc/jenkins-secrets/jenkins.env`.
6. `flush_handlers`, then wait until `GET /job/order-inventory/api/json` with the admin password returns 200.

`templates/casc.yaml.j2` (Jenkins Configuration as Code):

| Block | Meaning |
|---|---|
| `jenkins.securityRealm.local` | sign-up disabled; one user `admin` with password `${JENKINS_ADMIN_PASSWORD}` — a placeholder resolved by Jenkins from the environment file, so the file never contains the secret |
| `authorizationStrategy.globalMatrix` | `admin` has Overall/Administer; anonymous has nothing |
| `globalNodeProperties.envVars` | `CI_REPORTS_BUCKET` and `SONAR_HOST_URL` (`http://127.0.0.1:9000`) for all builds |
| `credentials` | string credential `sonarqube-token` = `${SONAR_TOKEN}` (used by `withCredentials` in the Jenkinsfile) |
| `unclassified.location.url` | `http://localhost:8080/` |
| `jobs` (Job DSL) | `pipelineJob('order-inventory')` with `pollSCM('H/5 * * * *')`, Git remote `jenkins_casc_repo_url`, branch `*/main`, `scriptPath('Jenkinsfile')` |

Result: a Jenkins that can be destroyed and rebuilt identically from code — no manual clicks.

## 7.6 Idempotency, error handling, linting and testing

- **Idempotency:** modules describe state (`apt state: present`, `file`, `copy` with content) and only change
  what differs; command-like tasks use `creates:`, `when:` checks or `changed_when: false`. Proof: re-runs report
  `changed=0` (container test and real host, `docs/TESTING.md`).
- **Handlers** run once at the end of a play (or at `flush_handlers`) and only if notified — e.g. Jenkins is
  restarted once even if three tasks changed its configuration.
- **Error handling:** `assert` with clear messages, `validate:` for sshd, retries/until for slow services and
  downloads, `failed_when: false` only on explicit check tasks.
- **Secrets:** `no_log: true` on every task that handles a password or token.
- **Lint/test:** `ansible/test/test-in-container.sh` starts an Ubuntu 24.04 container with systemd, runs
  `--syntax-check`, `ansible-lint` (production profile), applies the playbook, applies it again and requires
  `changed=0`, then checks Jenkins health. Evidence: `docs/evidence/ansible-container-test-2026-10-18.txt`
  (29 ok, 0 failed; second run changed=0). Real host: first run 49 ok / 24 changed / 0 failed, repeat runs
  `changed=0`; the GitHub switch run on 2026-10-19: ok=38 changed=3 failed=0.

## 7.7 Safe commands

```bash
# Connectivity only (run inside the same container approach or with a local Ansible):
ansible -i ansible/inventory.ini jenkins -m ping
# Dry run (no changes) through the wrapper:
SSH_KEY=... JENKINS_REPO_URL=https://github.com/SamruddhiDoke/DevOps-Project.git ./ansible/run-playbook.sh --check
# Apply, then apply again and expect "changed=0" in the PLAY RECAP:
SSH_KEY=... JENKINS_REPO_URL=https://github.com/SamruddhiDoke/DevOps-Project.git ./ansible/run-playbook.sh
```
Prerequisites: Jenkins EC2 running, its current IP in Terraform state (refresh-only apply), your IP allowed on
port 22 (the resume script maintains this).

## 7.8 Viva questions

| Question | Answer |
|---|---|
| Why both Terraform and Ansible? | Terraform provisions cloud resources through AWS APIs; Ansible configures software inside the server. Each is idempotent in its domain. |
| What is idempotency in Ansible? | Running the playbook again produces no changes when the host is already in the desired state (`changed=0`). |
| How do secrets reach Jenkins? | Terraform generates them into Secrets Manager → `run-playbook.sh` streams them on stdin into the Ansible container → Ansible writes a root:jenkins 0640 env file with `no_log` → JCasC reads `${…}` placeholders from the environment. |
| What are handlers? | Tasks run only when notified by a change, once, at the end of the play — e.g. restart Jenkins after its config changed. |
| What does `become: true` do? | Runs tasks with sudo as root on the target host. |
| Why is SonarQube bound to 127.0.0.1? | Only Jenkins on the same host needs it; admins use an SSH tunnel; nothing is exposed to the internet. |
| Why doesn't Ansible deploy the application? | Kubernetes/Helm provide rolling updates, readiness gating and rollback; the app runs on EKS, not on the Jenkins host. |
