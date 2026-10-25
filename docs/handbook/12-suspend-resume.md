# Part 15 — Suspend and resume implementation, line by line

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md)

Files: `scripts/lib/evaluation-common.sh` (shared library), `scripts/suspend-evaluation.sh`,
`scripts/resume-evaluation.sh`, `scripts/suspend-evaluation.ps1`, `scripts/resume-evaluation.ps1`,
`docs/recovery/evaluation-manifest.json`, plus Terraform lifecycle rules in `terraform/main.tf` (node group) and
`terraform/jenkins.tf` (instance). Runbook: `docs/RUNBOOKS.md` §10.

## 12.1 Suspension is not destruction

| | Suspend script | `terraform destroy` |
|---|---|---|
| Cluster, network, IAM, KMS, secrets, ECR, state | kept | deleted (secrets/KMS after 7-day windows) |
| Database | stopped, data + backups kept | **deleted without final snapshot** (`skip_final_snapshot = true`) |
| Jenkins | stopped, disk kept | instance and disk deleted |
| ALB | deleted by Kubernetes, recreated by Helm | must be deleted first or VPC deletion fails |
| Restore time | ≈ 10 min, one command, verified | ≈ 20+ min apply + Ansible + cluster bootstrap + first deployment |
| Cost while "off" | ≈ $4/day estimate (control plane, NAT, storage) | ≈ $0 |

## 12.2 Shared library `scripts/lib/evaluation-common.sh`

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
set -uo pipefail
```
Sourced (not executed) by both scripts. `-u`: using an unset variable is an error; `pipefail`: a pipeline fails
if any part fails. `-e` is deliberately **not** set: every important command is checked explicitly and fails
through `die` with a clear stage and reason.

```bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-order-inventory}"
export AWS_REGION="${AWS_REGION:-ap-south-1}"; export AWS_DEFAULT_REGION="$AWS_REGION"
EXPECTED_ACCOUNT="038215676861"; NAMESPACE="order-inventory"; RELEASE="order-inventory"
MANIFEST="$REPO_ROOT/docs/recovery/evaluation-manifest.json"; LOG_DIR="$REPO_ROOT/.deploy/evaluation-logs"
mkdir -p "$LOG_DIR" "$(dirname "$MANIFEST")"
```
Works from any current directory; profile and region default to the project's but can be overridden; the
expected account is a constant (safety: wrong account → stop).

```bash
ts() { date +%H:%M:%S; }   log() { echo "[$(ts)] $*"; }
stage() { STAGE="$1"; echo; echo "[$(ts)] ===== $1 ====="; }
ok() { echo "[$(ts)]   OK  $*"; }   warn() { echo "[$(ts)]   WARN $*"; }
die() { …prints "FAILED in stage: $STAGE", "reason: $*", diagnostic commands (sts identity, nodegroup
        status, kubectl get nodes/pods/ingress/events, RDS status, Jenkins state), and
        "The scripts are idempotent: fix the cause and run the same command again."; exit 1; }
```
Uniform, timestamped output; `STAGE` always holds the current stage name for error messages.

```bash
wait_until() {                     # wait_until <timeout-seconds> <description> <command...>
  local timeout="$1" desc="$2"; shift 2; local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    [ $((SECONDS - start)) -ge "$timeout" ] && die "timed out after ${timeout}s waiting for: $desc"
    sleep 10
  done
  ok "$desc ($((SECONDS - start))s)"
}
```
Polls a predicate every 10 s with an explicit timeout; prints how long it took (these are the durations in the
logs, e.g. "RDS available (165s)").

```bash
win_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }
TF_DIR="$(win_path "$REPO_ROOT/terraform")"
tfout() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null | tr -d '\r'; }
json_get() { node -e '…read file, walk dotted path, print value…' "$(win_path "$1")" "$2"; }
```
Windows Git Bash compatibility: `terraform.exe` and `node.exe` need Windows paths; `tr -d '\r'` removes Windows
line endings from CLI output. `tfout` reads Terraform outputs from the remote state; `json_get` reads the manifest.

`preflight()`:
1. all tools present (`aws terraform kubectl helm node curl`) else `die`;
2. `aws sts get-caller-identity` → ARN and account; `die` if the profile does not work, the account is not
   `038215676861`, or the ARN ends in `:root`;
3. `terraform init -input=false` (connects to the S3 backend) else `die`;
4. `CLUSTER=$(tfout eks_cluster_name)`, `RDS_ID=$(tfout rds_endpoint | cut -d. -f1)` (the identifier is the
   first label of the endpoint), `JENKINS_ID=$(tfout jenkins_instance_id)`,
   `REGISTRY=<account>.dkr.ecr.<region>.amazonaws.com`, `NODEGROUP` from `aws eks list-nodegroups`,
   `STATE_BUCKET` parsed from `terraform/backend.tf`; `die` if any is empty;
5. `aws s3api head-bucket` on the state bucket; cluster status must be `ACTIVE`.

`ensure_kube_access()`: `aws eks update-kubeconfig --name $CLUSTER --alias $CLUSTER`, `kubectl config
use-context`, `kubectl version --request-timeout=15s`; on failure: "cannot reach the Kubernetes API from this
machine (is your public IP allowed? …)".

State queries (all strip `\r`, all read-only): `rds_status`, `ec2_state`, `ng_field <jmespath>`,
`asg_instances` (instances in the node group's Auto Scaling group), `app_albs` (count of load balancers named
`k8s-orderinv*`). `print_cost_summary` prints control plane, node instances, Jenkins state, RDS state, ALB
count and NAT count. Predicates for `wait_until`: `rds_is <state>`, `ec2_is <state>`, `ng_active`,
`no_asg_instances`, `no_app_albs`, `no_app_tgs`, `http_200 <url>`.

## 12.3 `suspend-evaluation.sh`

| Lines | Code | What / why | Destructive? | Idempotency |
|---|---|---|---|---|
| 10 | `source …/lib/evaluation-common.sh` | load helpers | — | — |
| 12 | `PLAN_ONLY=false; [ "${1:-}" = "--plan" ] && PLAN_ONLY=true` | read-only mode | — | — |
| 13 | `exec > >(tee -a "$LOG_DIR/suspend-<timestamp>.log") 2>&1` | everything printed is also logged | — | — |
| 15 | `preflight` | identity, backend, IDs, cluster ACTIVE | no | — |
| 17–20 | read desired/min/max, instances, RDS, Jenkins, ALBs | current state | no | — |
| 22–23 | `ensure_kube_access` only if nodes exist | with 0 nodes there is nothing to do in Kubernetes | no | — |
| 25–34 | `--plan`: print what would happen + cost summary, `exit 0` | safe preview | no | — |
| 36–76 | **Stage 1 manifest:** if the backend Deployment exists, read the backend and frontend image tags (must be equal, else `die`), warn if not 2/2 ready, **verify both images exist in ECR** (else `die`: cannot guarantee restore), read the latest Helm revision and current ALB hostname, write the manifest JSON with Node (account, region, profile, backend bucket/key, cluster, node group sizes, RDS id + secret name, Jenkins id + secret name + repo, namespace/release/chart/revision/registry/repositories/`lastKnownGoodTag`/replicas/ingress/ALB hostname, logging replicas, `suspendedAt`, `rdsAutoRestartAfter` = now + 7 days) | records exactly what resume must restore; **no secrets** (only secret *names*) | no (writes a local file) | |
| 77–81 | else: keep the existing manifest (app already scaled down) or `die` if none | re-running after a partial suspend must not overwrite good data with an empty state | no | ✔ |
| 83–93 | **Stage 2 ALB:** if an app ALB exists: requires nodes (else `die` "resume first"); `helm upgrade … --reuse-values --set ingress.enabled=false --wait --timeout 5m`; wait (≤ 600 s) for 0 `k8s-orderinv` ALBs and (≤ 300 s) 0 target groups | deletes the Ingress through Helm (chart and values otherwise unchanged); the **controller deletes the ALB**, so this must run while the controller has nodes | **yes** (ALB deleted; recreatable) | skipped when no ALB |
| 94–98 | delete CloudWatch alarms named `order-inventory-alb*` | they refer to the deleted ALB | yes (recreated by resume) | no-op when none |
| 100–107 | **Stage 3:** `kubectl scale deploy backend frontend --replicas=0`; ES/Kibana to 0; confirm `kubectl get pv` is empty | pods gone cleanly before node drain (scaling is not an eviction, so PDBs do not block it); no PersistentVolumes means nothing on node disks needs saving | pods removed (Deployments kept) | ✔ |
| 109–116 | **Stage 4:** if desired ≠ 0: wait node group ACTIVE, `update-nodegroup-config minSize=0,maxSize=<max>,desiredSize=0`; wait (≤ 1500 s) for 0 ASG instances | EC2 workers terminated; Terraform ignores desired size, min 0 is allowed by `full.tfvars` | instances terminated (definition kept) | skipped if already 0; waiting is repeatable |
| 118–127 | **Stage 5:** record Jenkins root volume id, size, type, encryption; `stop-instances` if running/pending; nothing if stopped/stopping; `die` otherwise; wait for `stopped` (≤ 600 s) | proves the data volume exists before stopping | no (stop, not terminate) | ✔ |
| 129–137 | **Stage 6:** `stop-db-instance` only from `available`; nothing if stopped/stopping; `die` for other states (e.g. `backing-up`); wait for `stopped` (≤ 1200 s); warn about the 7-day automatic start | | no | ✔ |
| 139–151 | **Stage 7 verification:** cluster ACTIVE; ECR images for the manifest tag exist; the 3 secrets exist; state object exists in S3; RDS `LatestRestorableTime` (PITR); no app ALB remains (`die` otherwise) | proof that restore is possible | no | — |
| 153–155 | cost summary; "SUSPENDED. Restore with: bash scripts/resume-evaluation.sh" | | | |

Measured 2026-10-19: 1396 s and 1383 s (two runs); node termination 1027–1028 s of that.

## 12.4 `resume-evaluation.sh`

| Lines | Code | What / why |
|---|---|---|
| 11–16 | source library, log to `resume-<timestamp>.log`, `T0=$SECONDS`, `preflight` | |
| 17–25 | manifest must exist; read `lastKnownGoodTag`, `desiredSize`, `maxSize`; `NG_MIN_RUN=1`; `die` if incomplete; **both images for the tag must exist in ECR** | fail before changing anything |
| 27–55 | **Stage 1 admin IP:** `curl https://checkip.amazonaws.com` → this laptop's public IP; compare with the cluster's `publicAccessCidrs`. If missing: back up `terraform/admin.auto.tfvars` to `.bak`, write the new `/32`, run `terraform plan -target=aws_eks_cluster.main -target=…jenkins_ssh -target=…jenkins_web -out=…`, inspect the plan JSON with Node and **refuse** unless the only changes are an in-place `update` of `aws_eks_cluster.main` and create/delete of the two Jenkins SG rules; print the plan summary; `apply` exactly that saved plan | the only Terraform change resume may make; protects against accidental replacements. Dry-run of this branch on 2026-10-25: *2 to add, 1 to change, 2 to destroy*, guard accepts (not applied) |
| 57–64 | **Stage 2 RDS:** `stopped` → start; `available/starting/configuring-enhanced-monitoring/backing-up/modifying` → just log; `stopping` → wait until stopped, then start; other → `die` | handles the AWS auto-start (state `available`) |
| 65–71 | Jenkins: `stopped` → start; running/pending → log; `stopping` → wait then start | |
| 72–79 | node group: if desired < manifest desired: wait ACTIVE, `update-nodegroup-config minSize=1,maxSize=<max>,desiredSize=<2>` | the three start requests run in parallel in AWS; waiting happens later |
| 81–91 | **Stage 3:** `ensure_kube_access`; wait (≤ 1200 s) until ≥ 2 nodes `Ready`; print nodes; `kubectl rollout status` (≤ 600 s each) for `coredns`, `aws-load-balancer-controller`, `aws-node`, `kube-proxy`; Secret `mysql-secret` must exist | the controller must run before an Ingress can become an ALB |
| 93–94 | **Stage 4:** wait (≤ 1500 s) for RDS `available` | the backend needs the DB to become Ready |
| 96–104 | **Stage 5:** if the backend already has 2 replicas of `<registry>/order-inventory-backend:<tag>`, the Ingress exists and both deployments are 2/2 ready → skip; else `ROLLOUT_TIMEOUT=10m scripts/deploy-k8s.sh <registry> <tag>` | `helm upgrade` **without** `--reuse-values` → chart defaults: replicas 2/2 and `ingress.enabled: true`; automatic rollback on failure |
| 106–125 | **Stage 6:** wait for the Ingress hostname (≤ 600 s), ALB `active` (≤ 600 s), both `k8s-orderinv` target groups with ≥ 2 targets all `healthy` (≤ 900 s), and `http://<alb>/api/health` = 200 (≤ 600 s; covers DNS propagation) | |
| 127–135 | **Stage 7:** `/api/health`, `/api/health/ready`, `/` must be 200; print the last Flyway messages from the backend log; run the full read/write `smoke-test.sh` (20 checks) | proves DB connectivity, migrations state and real reads/writes |
| 137–142 | **Stage 8:** `create-alb-alarms.sh`; on failure only `warn` (the app is healthy) | |
| 144–162 | **Stage 9:** if namespace `logging` exists: scale ES/Kibana to 1, `rollout status` ES, Kibana, Filebeat; port-forward Kibana to 15601 in the background, poll `/api/status` for `available` (≤ 180 s), stop the port-forward | verifies ELK without exposing it |
| 164–170 | **Stage 10:** wait Jenkins `running`; read its **new** public IP from EC2 (not from Terraform state); wait for `/login` 200; `die` if its SG has any `0.0.0.0/0` rule | secure path check |
| 172–177 | **Stage 11:** manifest += `resumedAt`, `application.currentUrl`, `jenkins.publicIpAtResume`; remove `rdsAutoRestartAfter` | |
| 179–194 | summary block (URL, release, checks, Jenkins URL, Kibana command) | printed only after every check passed |

## 12.5 PowerShell wrappers (`scripts/*-evaluation.ps1`)

```powershell
$ErrorActionPreference = 'Stop'
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) { throw 'Git Bash not found: install Git for Windows' }
if (-not $env:AWS_PROFILE) { $env:AWS_PROFILE = 'order-inventory' }
Push-Location (Split-Path -Parent $PSScriptRoot)        # repository root
try { & $bash scripts/resume-evaluation.sh @args; exit $LASTEXITCODE } finally { Pop-Location }
```
Finds Git Bash, defaults the profile, runs the `.sh` with the same arguments (`@args`, e.g. `--plan`) from the
repository root and returns its exit code. Run with `powershell -ExecutionPolicy Bypass -File scripts\…ps1`
(bypass only for this process; the script is not signed). `.gitattributes` keeps `.ps1` files with CRLF.

## 12.6 Recovery manifest (`docs/recovery/evaluation-manifest.json`)

Fields at the last suspend: `awsAccount`, `awsRegion`, `awsProfile`; `terraformBackend` {bucket, key, lock};
`eks` {cluster, nodegroup, desiredSize 2, minSize 1, maxSize 3}; `rds` {identifier, secret *name*}; `jenkins`
{instanceId, adminSecret *name*, repo}; `application` {namespace, helmRelease, helmChart,
helmRevisionAtSuspend 14, registry, repositories, **lastKnownGoodTag `8-18a2bc6`**, replicas, ingress,
albHostnameAtSuspend}; `logging` {namespace, manifest, replicas}; `suspendedAt`; `rdsAutoRestartAfter`. It
contains no secret values and is committed so the restore information survives a lost laptop.

## 12.7 Order dependencies

Suspend: manifest → **ALB (needs controller → needs nodes)** → apps to 0 → nodes to 0 → Jenkins stop → RDS
stop → verify. Doing nodes first would leave an orphaned ALB that nothing can delete (the script detects that
and asks to resume first).

Resume: identity/backend → admin IP (else kubectl/Jenkins unreachable) → start RDS, Jenkins, nodes
(parallel) → nodes Ready + add-ons (controller, DNS, CNI) → RDS available (backend readiness needs it) → Helm
release (Ingress needs the controller) → ALB + healthy targets → functional tests → alarms (need the ALB) →
ELK → Jenkins check → manifest.

## 12.8 Interrupted halfway — what happens

Every step checks state first, so the remedy is always "run the same script again":

| Interrupted after | Re-running suspend | Re-running resume |
|---|---|---|
| manifest written | rewrites it from the still-running app | — |
| ALB deleted, apps still running | stage 2 skipped (no ALB); continues | Helm redeploys with Ingress |
| apps scaled to 0, nodes still up | manifest kept ("already scaled down"); continues | deploy-k8s restores 2/2 |
| node scale-down requested | waits for 0 instances | scales back up |
| Jenkins/RDS stop requested | waits for `stopped` | waits for stopped, then starts (`stopping` branch) |
| resume Terraform admin-IP step interrupted | — | the tfvars file already has the new IP; the next run plans again (S3 lock prevents parallel applies) |

## 12.9 What stays billable and why

See the handbook §1.5 and [06-terraform.md](06-terraform.md) §6.9: EKS control plane (cannot be paused), NAT
gateway + EIP (nodes need it to start; kept deliberately), EBS of Jenkins, RDS storage/backups, Secrets
Manager, KMS, alarms, ECR/S3 storage. Estimated ≈ $126/month on 2026-10-19 from list prices (not a verified
bill).

## 12.10 Troubleshooting

| Problem | Symptom (text printed by the scripts or AWS) | Fix |
|---|---|---|
| AWS credentials expired/invalid | `AWS CLI profile 'order-inventory' is not usable` | `aws configure --profile order-inventory` (new access key for the deployer user) and re-run |
| Wrong profile/account | `wrong AWS account (<id>), expected 038215676861` or `refusing to run as the root user` | `$env:AWS_PROFILE='order-inventory'` / `export AWS_PROFILE=order-inventory` |
| Terraform backend unavailable | `terraform init failed (S3 backend reachable?)` or `state bucket … not reachable` | check internet, credentials, bucket existence (`aws s3api head-bucket --bucket order-inventory-tfstate-038215676861`) |
| RDS fails to start | stuck in stage 4 / `timed out after 1500s waiting for: RDS available` | `aws rds describe-events --source-identifier order-inventory-mysql --source-type db-instance --duration 120`; re-run |
| Nodes Pending/NotReady | `timed out … node(s) Ready` | `kubectl get nodes`, `kubectl describe node`, node group health (`aws eks describe-nodegroup … --query nodegroup.health`), NAT gateway present |
| Jenkins has a new public IP | normal; printed in the summary | use the printed IP; `terraform apply -refresh-only …` before Ansible |
| ECR image not found | `ECR image order-inventory-backend:<tag> not found` | lifecycle policy keeps 20 images; pick an existing tag, edit `lastKnownGoodTag` in the manifest, re-run |
| Helm rollout times out | `Helm deployment of <tag> failed (deploy-k8s.sh rolled back if possible)` | `kubectl -n order-inventory get pods,events`; DB secret present? RDS available? re-run |
| ALB slow to become healthy | waiting on `ALB active` / target groups / `api/health returns 200` | new DNS can take minutes; `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| DNS/network fails on the laptop | `could not determine this machine's public IP`, `cannot reach the Kubernetes API` | check connectivity/VPN; re-run (updates the allowed IP when it can determine it) |
| Script run twice | prints `already …`, `skipped`, 55 s total on a running environment (measured) | nothing to do — idempotent |
| RDS restarted itself after 7 days | RDS `available` while everything else is suspended | run suspend again: only stage 6 does work |
| ALB exists but no nodes | `an application ALB exists but the cluster has no nodes … resume first` | run resume, then suspend |

## 12.11 Test record (2026-10-19)

| Test | Result |
|---|---|
| `bash -n`, shellcheck 0.10.0 (`-S warning`) on all three files | clean |
| `suspend --plan` (Git Bash and PowerShell wrapper) | correct preview, no changes |
| Suspend #1 | exit 0, 1396 s; independent checks: 0 LBs, 0 k8s target groups, 0 running instances, RDS/Jenkins stopped, ECR (incl. unrelated `frontend`) intact, KMS enabled |
| `terraform plan` while suspended | found the Jenkins replacement risk → fixed with `ignore_changes` → no resource changes |
| Resume | exit 0, **9 min 14 s**, all stages, 20/20 smoke checks, new ALB |
| Resume again (idempotency) | exit 0, 55 s, nothing changed |
| Suspend #2 (after build #8) | exit 0, 1383 s, manifest tag `8-18a2bc6` |
| Admin-IP branch | targeted plan dry-run 2026-10-25 only (accepted by the guard); apply not yet executed |
