# Complete Project Handbook and Viva Guide

**Production-Grade Microservices Platform with Zero-Downtime Deployment — Order & Inventory Management System**

This handbook explains the project as it is actually implemented in this repository and as it was actually
deployed on AWS. It is the main learning document; each technical area has a companion chapter in
[`docs/handbook/`](handbook/) with file-by-file and line-by-line explanations. A one-page version for the
day itself is [EVALUATION_DAY_CHEAT_SHEET.md](EVALUATION_DAY_CHEAT_SHEET.md).

How to read the facts in this handbook:

- **Project fact** — taken from a file in this repository (a path is always given) or from a recorded
  execution (an evidence file or a command run during the preparation of this handbook, with its date).
- *General knowledge* — explanation of how a technology works in general; marked "In general, …" where it
  could be confused with a project fact.
- Status labels: **VERIFIED** (executed and observed to work, evidence named) · **IMPLEMENTED BUT NOT
  VERIFIED** (code exists, no execution evidence) · **BLOCKED** (cannot be done without access/approval) ·
  **NOT IMPLEMENTED**.
- No secret values appear anywhere in this handbook. Where a secret is needed, the handbook names where it
  is stored and the command that retrieves it.

---

## Table of contents

1. [Evaluation-Day Quick Start, Verification, and Shutdown Runbook](#1-evaluation-day-quick-start-verification-and-shutdown-runbook)
   - [1.1 Verified current state](#11-verified-current-state)
   - [1.2 Exact resume instructions](#12-exact-resume-instructions)
   - [1.3 Pre-evaluation readiness check](#13-pre-evaluation-readiness-check)
   - [1.4 Live demonstration plan](#14-live-demonstration-plan)
   - [1.5 Exact shutdown instructions](#15-exact-shutdown-instructions)
2. [Complete project overview](#2-complete-project-overview)
3. [Component status matrix](#3-component-status-matrix)
4. [Companion chapters (Parts 3–19)](#4-companion-chapters-parts-319)

Companion chapters:

| Part | Chapter |
|---|---|
| 3 | [Repository and file-by-file inventory](handbook/01-repository-inventory.md) |
| 4–5 | [Frontend: React, JavaScript, Vite — line by line](handbook/02-frontend.md) |
| 4, 6 | [Backend: Java, Spring Boot — line by line](handbook/03-backend.md) |
| 7 | [MySQL, RDS and Flyway](handbook/04-database.md) |
| 8 | [Docker and Docker Compose](handbook/05-docker.md) |
| 9 | [Terraform: every file and every resource](handbook/06-terraform.md) |
| 10 | [Ansible](handbook/07-ansible.md) |
| 11 | [Jenkins and CI/CD](handbook/08-jenkins-cicd.md) |
| 12 | [EKS, Kubernetes, Helm and the ALB](handbook/09-kubernetes-helm-eks.md) |
| 13 | [SonarQube, Trivy and security](handbook/10-security.md) |
| 14 | [CloudWatch, SNS, SQS, Budgets and ELK](handbook/11-monitoring-logging.md) |
| 15 | [Suspend and resume implementation, line by line](handbook/12-suspend-resume.md) |
| 16 | [Architecture diagrams and request flows](handbook/13-diagrams.md) |
| 17 | [Viva and cross-question bank](handbook/14-viva-question-bank.md) |
| 18 | [Presentation and explanation scripts](handbook/15-presentation-scripts.md) |
| 19 | [Glossary and concept guide](handbook/16-glossary.md) |

---

## 1. Evaluation-Day Quick Start, Verification, and Shutdown Runbook

### 1.1 Verified current state

Checked read-only on **2026-10-25** with the `order-inventory` CLI profile (nothing was changed):

| Item | Observed state | How it was checked |
|---|---|---|
| AWS identity | account `038215676861`, `arn:aws:iam::038215676861:user/order-inventory-deployer` | `aws sts get-caller-identity` |
| Region | `ap-south-1` (Mumbai) | profile + scripts (`AWS_REGION` default in `scripts/lib/evaluation-common.sh`) |
| EKS cluster | `order-inventory-eks`, **ACTIVE**, Kubernetes 1.36 | `aws eks describe-cluster` |
| Node group | `order-inventory-nodes`, ACTIVE, **min 0 / desired 0 / max 3**, 0 running instances | `aws eks describe-nodegroup` |
| RDS | `order-inventory-mysql`, **stopped**, MySQL 8.4.11, db.t3.micro; last event "DB instance stopped" 2026-10-18 21:34 UTC | `aws rds describe-db-instances`, `describe-events` |
| Jenkins EC2 | `i-03288b455e674765e`, **stopped**, no public IP while stopped | `aws ec2 describe-instances` |
| Running EC2 instances in the region | 0 | `aws ec2 describe-instances` (filter running/pending) |
| Load balancers | **0** (application ALB removed) | `aws elbv2 describe-load-balancers` |
| NAT gateway | 1 available (kept on purpose, see §1.5) | `aws ec2 describe-nat-gateways` |
| ECR backend tags | `2-06f7acc`, `4-bf7450d`, `5-eaf6380`, `6-ca5c22c`, `7-ca5c22c`, `8-18a2bc6` | `aws ecr describe-images` |
| CloudWatch alarms | 9 Terraform alarms present; `INSUFFICIENT_DATA` (expected: nothing is emitting metrics), NAT alarm `OK`; the 4 ALB alarms were deleted by the suspend script and are recreated by resume | `aws cloudwatch describe-alarms` |
| AWS Budget `order-inventory-monthly` | limit $350; AWS Budgets reported actual spend **$0.00** and forecast **$7.13** for October on 2026-10-25 (Budgets data can lag and is net of any credits, so treat it as indicative only) | `aws budgets describe-budgets` |
| Git | local `main` = `origin/main` = `b5f0454`; working tree clean before this handbook | `git status`, `git fetch` |
| Recovery manifest | [`docs/recovery/evaluation-manifest.json`](recovery/evaluation-manifest.json): `lastKnownGoodTag` **`8-18a2bc6`**, Helm revision at suspend **14**, `suspendedAt` 2026-10-18T21:13 UTC, `rdsAutoRestartAfter` **2026-10-25T21:13 UTC** | file |

What this means, in plain words:

- The release that resume will deploy is **`8-18a2bc6`** (Jenkins build #8, commit `18a2bc6`, triggered
  automatically by Jenkins polling GitHub). `7-ca5c22c` was the previous known-good release; it is still in
  ECR and can be redeployed manually.
- `b5f0454` (and the commit that adds this handbook) changed only documentation and the manifest. They
  have **not been built by Jenkins yet**: Jenkins was stopped when they were pushed. After the next
  resume, Jenkins will notice them within 5 minutes and run a full build and deploy by itself (see §1.2.6).
- **RDS auto-start:** AWS starts a stopped RDS instance automatically after 7 days. For this instance that
  is around **2026-10-25 21:13 UTC (2026-10-26 02:43 IST)**. If you are not using the environment then,
  re-run the suspend script afterwards (§1.5); it will only stop RDS again.
- **Your public IP has changed** since the last resume (checked 2026-10-25: it no longer matches
  `terraform/admin.auto.tfvars`). Resume handles this automatically (§1.2.4, stage 1); a read-only dry run
  of that step was executed on 2026-10-25 and produced exactly the expected targeted plan (EKS API CIDR
  updated in place, the two Jenkins security-group rules replaced: *2 to add, 1 to change, 2 to destroy*),
  which the script's safety guard accepts. The real apply of this branch has **not** been executed yet
  (IMPLEMENTED; plan VERIFIED).

> **Cost figures.** The suspended cost of ≈ $126/month (≈ $4.15/day) and the running cost of ≈ $311/month
> in [AWS_DEPLOYMENT.md](AWS_DEPLOYMENT.md) were *estimates computed on 2026-10-18/19 from on-demand list
> prices*. They are not invoices. Check real charges in the AWS Billing console / Cost Explorer.

### 1.2 Exact resume instructions

#### 1.2.1 Open the right directory

Everything is run from the repository root:

```powershell
cd "C:\Users\Siddesh\Desktop\DevOps Project"
```

The scripts find the repository root themselves (`REPO_ROOT` in `scripts/lib/evaluation-common.sh`), but the
PowerShell wrapper paths (`scripts\resume-evaluation.ps1`) are relative to this directory.

#### 1.2.2 Prerequisites on the laptop

| Tool | Why | Check |
|---|---|---|
| Git for Windows (Git Bash) | runs the `.sh` scripts; the `.ps1` wrappers call `C:\Program Files\Git\bin\bash.exe` | `git --version` |
| AWS CLI v2 with profile `order-inventory` | every AWS call | `aws --version` · `aws sts get-caller-identity --profile order-inventory` |
| Terraform ≥ 1.10 (1.15.8 used) | `terraform init` (reads outputs from the S3 state) and the targeted admin-IP update | `terraform -version` |
| kubectl | talks to EKS | `kubectl version --client` |
| Helm 4.x | deploys the release | `helm version --short` |
| Node.js ≥ 20.19 | small JSON helpers inside the scripts | `node -v` |
| curl | health checks | `curl --version` |
| Internet access from the laptop | EKS API, ALB, ECR, AWS APIs | — |

The script checks all of these itself in its **Preflight** stage and stops with a clear message if one is
missing (`preflight()` in `scripts/lib/evaluation-common.sh`).

#### 1.2.3 Confirm identity and region (do this first)

```powershell
aws sts get-caller-identity --profile order-inventory
```

Must show account `038215676861` and `user/order-inventory-deployer`. The scripts refuse to run in any other
account (`EXPECTED_ACCOUNT="038215676861"`) and refuse the root user (`case "$arn" in *":root") die ...`).
The region is forced to `ap-south-1` by the scripts (`AWS_REGION` defaults to `ap-south-1`).

#### 1.2.4 Run the restore

PowerShell (wrapper, verified working with `suspend-evaluation.ps1 --plan` on 2026-10-19):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\resume-evaluation.ps1
```

Git Bash (the form used for the end-to-end resume test on 2026-10-19):

```bash
bash scripts/resume-evaluation.sh
```

The `.ps1` file only locates Git Bash, sets `AWS_PROFILE=order-inventory` if it is not already set,
changes to the repository root and runs the `.sh` script with the same arguments; the exit code is passed
back. All logic is in the `.sh` script.

What happens, in order (stage names exactly as printed by the script):

| Stage | What it does | Typical duration (measured 2026-10-19) |
|---|---|---|
| Preflight | tools present; AWS identity = expected account, not root; `terraform init` against the S3 backend; reads cluster/RDS/Jenkins IDs from Terraform outputs; state bucket reachable; cluster ACTIVE; manifest present; both ECR images for the manifest tag exist | 11 s |
| 1. Admin network access | compares this laptop's public IP with the EKS API allow-list; if different, rewrites the git-ignored `terraform/admin.auto.tfvars` and applies a **targeted** plan (EKS API CIDRs + two Jenkins SG rules only; anything else → refuse) | 1 s when unchanged; *several extra minutes when the IP changed (EKS endpoint update; not measured)* |
| 2. Start RDS, Jenkins EC2 and the EKS node group (in parallel) | `start-db-instance`, `start-instances`, `update-nodegroup-config` (min 1, desired 2, max 3). Only requests; waiting happens later | 8 s |
| 3. Kubernetes nodes and cluster add-ons | updates kubeconfig; waits for 2 nodes `Ready`; waits for `coredns`, `aws-load-balancer-controller`, `aws-node`, `kube-proxy`; checks Secret `mysql-secret` exists | ≈ 1.5 min |
| 4. Database | waits for RDS `available` | ≈ 3 min (RDS start took ≈ 4 min in total) — **longest stage** |
| 5. Application release `<tag>` | runs `scripts/deploy-k8s.sh <registry> <tag>` = `helm upgrade --install --wait` with chart defaults (2+2 replicas, Ingress enabled) and automatic rollback on failure | ≈ 1 min |
| 6. Application Load Balancer | waits for the Ingress hostname, the ALB `active`, both target groups with ≥ 2 healthy targets, and `/api/health` = 200 through the new DNS name | ≈ 1 min |
| 7. Database connectivity, migrations and smoke tests | `/api/health`, `/api/health/ready`, `/` = 200; prints the Flyway log lines; runs the full **read/write** `scripts/smoke-test.sh` (20 checks) | ≈ 10 s |
| 8. ALB alarms | `scripts/create-alb-alarms.sh` recreates the 4 ALB alarms for the new ALB | ≈ 7 s |
| 9. Logging (ELK) | scales Elasticsearch and Kibana to 1, waits for them and the Filebeat DaemonSet, checks Kibana `/api/status` through a temporary `kubectl port-forward` | ≈ 2.5 min |
| 10. Jenkins | waits for the EC2 instance, reads its **new** public IP, waits for `http://<ip>:8080/login` = 200, checks the security group has no `0.0.0.0/0` rule | seconds (Jenkins had been booting since stage 2) |
| 11. Update recovery manifest | writes `resumedAt`, `application.currentUrl`, `jenkins.publicIpAtResume` | < 1 s |

Total measured on 2026-10-19: **9 min 14 s** (`docs/AWS_DEPLOYMENT.md`, "How it was verified"). A second
run on the already-running environment finished in **55 s** and changed nothing (idempotency check).

How to recognise success at each stage: every successful step prints a line starting with `OK`, for
example (copied from the 2026-10-19 resume log, IDs as they were then):

```text
[02:22:24]   OK  2 node(s) Ready (43s)
[02:25:41]   OK  RDS available (165s)
[02:27:45]   OK  both ALB target groups have >=2 healthy targets (4s)
All 20 checks passed against http://k8s-orderinv-orderinv-00335110a2-1122521152.ap-south-1.elb.amazonaws.com
```

A failure prints `FAILED in stage: <stage>`, the `reason:` and a list of diagnostic commands, then exits
with code 1. **Fix the reason and run the same command again**; every step first checks the current state.

The final output block (format from `scripts/resume-evaluation.sh` lines 180–194; values differ every time):

```text
=====================================================================
 ENVIRONMENT RESTORED AND VERIFIED in 9m 14s
   Application : http://<new ALB hostname>
   Release     : 8-18a2bc6 (Helm release order-inventory, namespace order-inventory)
   Checks      : nodes Ready, add-ons ready, RDS available, 2/2 backend + 2/2 frontend,
                 ALB targets healthy, health/readiness 200, read/write smoke test passed,
                 ELK ready, Jenkins /login 200
   Jenkins     : http://<new public IP>:8080   (admin /32 only; password: Secrets Manager order-inventory/jenkins-admin)
   Kibana      : kubectl -n logging port-forward svc/kibana 5601:5601  ->  http://localhost:5601
   Note        : the ALB hostname and Jenkins IP can differ from the previous run.
   Suspend     : bash scripts/suspend-evaluation.sh
=====================================================================
```

Logs of every run are kept in `.deploy/evaluation-logs/` (git-ignored).

#### 1.2.5 Get the application URL at any time

```bash
export AWS_PROFILE=order-inventory AWS_REGION=ap-south-1
kubectl -n order-inventory get ingress order-inventory-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
```

It is also written to `docs/recovery/evaluation-manifest.json` → `application.currentUrl` after each resume.
**Why it changes:** suspend deletes the Ingress, so the AWS Load Balancer Controller deletes the ALB; resume
creates a new Ingress, and AWS assigns the new ALB a new DNS name. The same applies to Jenkins: it has no
Elastic IP (to avoid paying for an idle address), so AWS gives it a new public IP on each start.

#### 1.2.6 After the restore — things that happen by themselves

1. **Jenkins builds the newest commit.** The job polls GitHub every 5 minutes (`H/5 * * * *` in
   `ansible/roles/jenkins_casc/defaults/main.yml`). Any commit pushed while Jenkins was stopped (at least the
   documentation commits) triggers a full pipeline: tests → SonarQube → Trivy → images `9-<commit>` → ECR →
   Helm rolling update → checks through the ALB. Expect it roughly 5–15 minutes after resume, taking about
   8 minutes (build #8 ran its backend tests at 21:05 UTC and finished its ALB checks at 21:11 UTC). It is a zero-downtime rolling
   update, so the site stays up. **Recommendation:** start resume at least 45 minutes before the evaluation
   and let this build finish, or use it deliberately as the live CI/CD demonstration.
2. **Kibana is empty.** Elasticsearch keeps its data in an `emptyDir` volume (`k8s/logging/elk.yaml`), which
   disappeared with the worker nodes. Logs from after the resume are collected again by Filebeat, but the
   Kibana data view and the *Order Inventory – Operations* dashboard (saved inside Elasticsearch) must be
   re-imported:
   ```bash
   kubectl -n logging port-forward svc/kibana 5601:5601      # terminal 2, leave running
   bash order-inventory-platform/logging/kibana-setup.sh http://localhost:5601
   ```
   Status: re-import after a resume is IMPLEMENTED BUT NOT VERIFIED (the script itself was verified on
   2026-10-18/19: "6 objects, success").

#### 1.2.7 Verify the application before the evaluation starts

```bash
export AWS_PROFILE=order-inventory AWS_REGION=ap-south-1
URL=http://$(kubectl -n order-inventory get ingress order-inventory-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s $URL/api/health          # {"status":"UP"}                    liveness (no DB)
curl -s $URL/api/health/ready    # {"status":"UP","database":"UP"}    readiness (DB reachable)
SMOKE_READ_ONLY=1 bash scripts/smoke-test.sh $URL     # 8 read-only checks, creates nothing
```

Then open `$URL` in the browser: Dashboard shows the counts, the header badge says **API Online**.

#### 1.2.8 Exam-pressure checklist (tick in order)

- [ ] `cd "C:\Users\Siddesh\Desktop\DevOps Project"`
- [ ] `aws sts get-caller-identity --profile order-inventory` → deployer user, account 038215676861
- [ ] Run resume (PowerShell wrapper or Git Bash) ≥ 45 minutes before the slot
- [ ] Final block shows `ENVIRONMENT RESTORED AND VERIFIED`
- [ ] Copy the **Application** URL and the **Jenkins** URL into a text file
- [ ] Open the app; header shows "API Online"
- [ ] Copy the Jenkins password to the clipboard (§1.4 step 5), log in, watch the automatic build finish green
- [ ] Start the Kibana port-forward and run `kibana-setup.sh`
- [ ] Open `docs/evidence/aws-zero-downtime-2026-10-19.txt` and `docs/ARCHITECTURE.md` in tabs
- [ ] Keep this handbook and the cheat sheet open

### 1.3 Pre-evaluation readiness check

Run these the day before (all read-only unless marked):

| # | Check | Command | Expected success |
|---|---|---|---|
| 1 | GitHub repository and latest commit | `git fetch origin && git rev-list --left-right --count main...origin/main && git log -1 --oneline origin/main` | `0	0` (nothing ahead or behind; local `main` has no upstream configured since the history rewrite, so `git status` does not show this) and the expected latest commit |
| 2 | AWS identity and permissions | `aws sts get-caller-identity --profile order-inventory` | deployer user in account 038215676861 |
| 3 | Region | `aws configure get region --profile order-inventory` | `ap-south-1` (scripts force it anyway) |
| 4 | Local tools | `aws --version; terraform -version; kubectl version --client; helm version --short; node -v; curl --version` | all print versions |
| 5 | Terraform state reachable + whole preflight | `bash scripts/suspend-evaluation.sh --plan` | preflight `OK` lines and "Plan (no changes made)" — this mode changes nothing |
| 6 | Recovery manifest | `node -e "console.log(require('./docs/recovery/evaluation-manifest.json').application.lastKnownGoodTag)"` | `8-18a2bc6` (or the newer tag recorded at the last suspend) |
| 7 | ECR images for that tag | `aws ecr describe-images --repository-name order-inventory-backend --image-ids imageTag=8-18a2bc6 --profile order-inventory --region ap-south-1 --query 'imageDetails[0].imageTags'` (repeat for `order-inventory-frontend`) | the tag is listed |
| 8 | RDS state | `aws rds describe-db-instances --db-instance-identifier order-inventory-mysql --profile order-inventory --region ap-south-1 --query 'DBInstances[0].DBInstanceStatus'` | `stopped` (or `available` if AWS auto-started it) — both are handled by resume |
| 9 | Full rehearsal (**changes AWS state; costs money while running**) | resume → checks below → suspend | as in §1.2 and §1.5 |

After a resume (or during the rehearsal):

| Check | Command | Expected |
|---|---|---|
| EKS nodes | `kubectl get nodes` | 2 nodes `Ready` |
| Helm rollout | `helm -n order-inventory history order-inventory --max 3` | last revision `deployed` |
| Pods | `kubectl -n order-inventory get pods` | 2 `backend-*` and 2 `frontend-*` `1/1 Running` |
| Ingress / ALB | `kubectl -n order-inventory get ingress` | `ADDRESS` = `k8s-orderinv-...elb.amazonaws.com` |
| ALB target health | `aws elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName,'k8s-orderinv')].TargetGroupArn" --output text` then `aws elbv2 describe-target-health --target-group-arn <arn>` | every target `healthy` |
| Backend/frontend health | `curl -s $URL/api/health/ready` · `curl -sI $URL/` | `{"status":"UP","database":"UP"}` · `HTTP/1.1 200` |
| Database migrations | `kubectl -n order-inventory logs deploy/backend \| grep -i flyway` | "Successfully validated 2 migrations", "Schema ... is up to date" |
| Database read/write | `bash scripts/smoke-test.sh $URL` | `All 20 checks passed` (creates a uniquely named user/product/order and cancels the order) |
| ELK | `kubectl -n logging get pods` | elasticsearch, kibana, filebeat-* Ready |
| Kibana | port-forward + http://localhost:5601 | Kibana UI loads |
| CloudWatch alarms | `aws cloudwatch describe-alarms --alarm-name-prefix order-inventory --query 'MetricAlarms[].[AlarmName,StateValue]' --output table` | 13 alarms; `OK` (newly created alarms show `INSUFFICIENT_DATA` for a few minutes) |
| Jenkins | browser `http://<jenkins-ip>:8080` | login page; job `order-inventory` last build green |
| Browser and network | open the ALB URL on the laptop used for the demo | UI loads; **Jenkins and the EKS API only work from the IP that ran resume** |

**Fallback demonstration if AWS or the internet fails** (no AWS needed):

1. Local stack: `cd order-inventory-platform` → `docker compose up -d --build` → http://localhost:3000 (Docker
   Desktop required; first build downloads base images, so do it once beforehand while online).
2. Local tests: `cd order-inventory-platform/backend; mvn -B verify` (29 tests) and
   `cd ../frontend; npm ci; npm test` (21 tests) — requires JDK/Maven/Node locally and previously
   downloaded dependencies.
3. Recorded evidence in `docs/evidence/` (zero-downtime test, RDS interruption, ELK trace, Jenkins builds #7
   and #8) and the results tables in `docs/TESTING.md`.
4. Architecture diagrams in [handbook/13-diagrams.md](handbook/13-diagrams.md) (Mermaid renders on GitHub
   and in VS Code with a Mermaid preview extension).

### 1.4 Live demonstration plan

Duration: 8–10 minutes. Never break the live system during the evaluation. Failure behaviour is shown with recorded evidence.

| # | Time | Action | What to say |
|---|---|---|---|
| 1 | 0:00 | Show the runtime diagram ([13-diagrams.md](handbook/13-diagrams.md) §1). | "Browser → ALB → frontend/back-end pods on EKS in private subnets → RDS in isolated DB subnets. Jenkins builds and deploys; Terraform created all of it; Ansible configured Jenkins." |
| 2 | 0:45 | Open the ALB URL. Dashboard → Products. | "The UI is React served by nginx. It calls `/api` on the same origin; the ALB sends `/api` to the Spring Boot pods." |
| 3 | 1:30 | Orders → **Create Order** → choose a customer and a product with stock, quantity 2 → Confirm. Go to Products: stock is 2 lower. Orders → **Status → CANCELLED**: stock is restored. | "Creating an order locks the product rows (`SELECT … FOR UPDATE`) inside one transaction, so two buyers cannot both take the last unit. Cancelling returns the stock exactly once; a cancelled order is final." |
| 4 | 2:30 | Show the API directly: `curl -s $URL/api/products/1` and an error: `curl -s -X POST $URL/api/orders -H "Content-Type: application/json" -d '{"userId":1,"items":[{"productId":1,"quantity":999999}]}'` | Point at `"status":400`, the message and the `requestId` in the error body. |
| 5 | 3:15 | Jenkins (`http://<jenkins-ip>:8080`, user `admin`, password copied with `aws secretsmanager get-secret-value --secret-id order-inventory/jenkins-admin --query SecretString --output text --profile order-inventory --region ap-south-1 \| Set-Clipboard`). Open the job → the automatic build that ran after resume (or click **Build with Parameters**, DEPLOY ✔, FULL_SMOKE_TEST ✘). | "Every push to GitHub is detected by polling; the stages are tests, SonarQube quality gate, Trivy gates, image build, ECR push, Helm deploy, verification, automatic rollback." |
| 6 | 4:30 | Images and tags: `aws ecr describe-images --repository-name order-inventory-backend --query 'imageDetails[].imageTags[]' --output text` | "Tags are `<build>-<commit>` and the repository is IMMUTABLE, so a tag always means the same image; rollback = redeploy an older tag." |
| 7 | 5:00 | Kubernetes: `kubectl -n order-inventory get deploy,rs,pods,svc,ingress` and `helm -n order-inventory history order-inventory --max 5` | Deployment → ReplicaSet per version → Pods; Services; Ingress = ALB; Helm revisions = releases you can roll back to. |
| 8 | 6:00 | Zero downtime evidence: `docs/evidence/aws-zero-downtime-2026-10-19.txt` | "9,532 requests through the real ALB during two releases, a bad image, an unhealthy release and a restart: 0 errors; both failed releases were rolled back automatically." |
| 9 | 7:00 | Monitoring and logs: CloudWatch alarm list; Kibana → Discover → paste the `requestId` from step 4. | "One request id links the nginx access line and the backend warning, with pod and namespace metadata." |
| 10 | 8:00 | Cost: show `scripts/suspend-evaluation.sh` stages and §1.5 table. | "Between demos the system is suspended, not destroyed: no nodes, no ALB, Jenkins and RDS stopped; one command restores and verifies it in about 10 minutes." |

### 1.5 Exact shutdown instructions

After the evaluation, from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\suspend-evaluation.ps1 --plan   # read-only preview
powershell -ExecutionPolicy Bypass -File scripts\suspend-evaluation.ps1          # suspend
```

Git Bash: `bash scripts/suspend-evaluation.sh --plan` and `bash scripts/suspend-evaluation.sh`.

Measured on 2026-10-19 (twice): about **23 minutes**, of which about **17 minutes** (1,027–1,028 s) is
EKS terminating the two nodes. *In general*, a managed node group drains each node before terminating it
and waits for pod evictions (which PodDisruptionBudgets can block) up to a timeout of about 15 minutes; the
measured duration matches that timeout, but the exact pod that held the drain was not recorded. Success ends with:

```text
SUSPENDED. Restore with:  bash scripts/resume-evaluation.sh
```

What the suspend script does (details in [12-suspend-resume.md](handbook/12-suspend-resume.md)):

| Order | Action | Why in this order |
|---|---|---|
| 1 | Writes `docs/recovery/evaluation-manifest.json` (running tag, Helm revision, node-group sizes, IDs; no secrets) | resume restores exactly this release |
| 2 | `helm upgrade --reuse-values --set ingress.enabled=false`; waits until the `k8s-orderinv` ALB and target groups are gone; deletes the 4 ALB alarms | the controller that deletes the ALB runs **on the nodes**, so this must happen before the nodes go |
| 3 | Scales backend/frontend and Elasticsearch/Kibana to 0 | lets the nodes drain cleanly; there are no PersistentVolumes |
| 4 | Node group min 0 / desired 0 (max kept); waits for 0 instances | Terraform ignores `desired_size` and has `node_min_size = 0`, so this is not "drift" |
| 5 | Stops Jenkins EC2 | Jenkins home, jobs, plugins and SonarQube volumes are on the retained 30 GB encrypted root EBS volume |
| 6 | Stops RDS | storage, automated backups and point-in-time recovery are retained |
| 7 | Verifies cluster, images, secrets, state file, PITR window, no ALB | proves nothing needed for restore was lost |

| State after suspend | Resources |
|---|---|
| **Stopped / removed** (no compute charge) | worker nodes (0), application ALB + target groups (deleted; recreated by resume), Jenkins EC2 (stopped), RDS instance (stopped), application and ELK pods (0 replicas), 4 ALB alarms (deleted; recreated) |
| **Still active and billed** | EKS control plane (≈ $0.10/h, cannot be paused), NAT gateway (≈ $0.056/h) + its Elastic IP, Jenkins EBS volume, RDS storage and backups (backup storage up to the DB size is free), Secrets Manager (3 secrets), KMS key, 9 CloudWatch alarms, ECR images, S3 (state + CI reports) |
| **Preserved data** | RDS database (storage + 7-day PITR), Jenkins configuration and build history (EBS), SonarQube data (Docker volumes on the same EBS), all ECR images, Terraform state (S3, versioned), secrets, KMS key |
| **Lost on purpose** | Elasticsearch logs (demo `emptyDir`), worker-node local disks (nothing stored there: no PVs) |

**Why not `terraform destroy`?** Destroy deletes everything Terraform manages, including the database:
`terraform/main.tf` sets `skip_final_snapshot = true` and `deletion_protection = false` on
`aws_db_instance.mysql` (lab settings for a clean teardown), so a destroy would delete the database **without
a final snapshot**, delete the secrets (7-day recovery window), schedule the KMS key for deletion and lose
ECR images (`force_delete = true`). Rebuilding would take about 20+ minutes of `apply` plus the Ansible run,
cluster bootstrap and a new first deployment. Suspension keeps all of that and costs a few dollars a day.

**RDS 7-day limit.** AWS restarts a stopped RDS instance after 7 days. The manifest records the date
(`rdsAutoRestartAfter`). Re-run the suspend script after that date: it finds no nodes, no ALB, Jenkins
stopped, RDS available → stops only RDS.

Recovery from common failures:

| Failure | Recovery |
|---|---|
| Interrupted (laptop closed, network lost) | Run the same script again. Each step checks the current state (e.g. skips the Helm change when no ALB exists, skips the node-group update when desired is already 0). |
| `an application ALB exists but the cluster has no nodes to run the controller; resume first` | Nodes were removed before the ALB. Run resume (it recreates nodes and the release), then suspend again. |
| `RDS is '<state>'; it can only be stopped from 'available'` | Wait until RDS finishes its current operation (`backing-up`, `modifying`, …) and re-run. |
| Drain takes > 25 min (`timed out ... all worker instances terminated`) | `aws eks describe-nodegroup --cluster-name order-inventory-eks --nodegroup-name order-inventory-nodes --query nodegroup.health`; re-run (it continues waiting). |
| `cannot reach the Kubernetes API` | Your IP changed while nodes still exist. Run resume once (updates the allow-list), then suspend. |

---

## 2. Complete project overview

### 2.1 In simple English

A small company sells products and needs to keep track of **customers, products in stock and orders**. When
an order is placed, the stock must go down; when an order is cancelled, the stock must come back; it must
never be possible to sell more items than exist. That is the application.

The real focus of the project is **how the application is built, tested, secured, deployed, monitored and
operated**: every change goes through an automated pipeline that tests it, checks code quality and security,
packages it into containers, stores them in a registry and rolls them out to a Kubernetes cluster on AWS
**without any downtime**, rolling back by itself if the new version is unhealthy. All cloud infrastructure is
written as code (Terraform), the build server is configured as code (Ansible + Jenkins Configuration as Code),
and the environment can be suspended and restored with one command to control cost.

### 2.2 Title, problem, motivation

| Item | Content |
|---|---|
| Title | Production-Grade Microservices Platform with Zero-Downtime Deployment — Order & Inventory Management System |
| Problem statement | Manual deployments of business applications cause downtime, configuration drift, unreviewed security risk and unpredictable cost. Inventory systems additionally need correctness under concurrent orders. |
| Motivation | Learn and demonstrate the full path from source code to a monitored, secured cloud deployment, with evidence for each claim (tests, scans, measured zero-downtime runs). |

### 2.3 Objectives (and where each is met)

| Objective | Implementation | Status |
|---|---|---|
| Correct order/inventory logic under concurrency | pessimistic row locks in `OrderService.createOrder` + DB `CHECK` constraints; `OrderConcurrencyTest` (8 buyers, 3 units) | VERIFIED (H2 test; mutation check documented in `docs/TESTING.md`) |
| Automated CI/CD from GitHub to EKS | `Jenkinsfile`, Jenkins on EC2 polling GitHub | VERIFIED (builds #7, #8) |
| Quality and security gates | SonarQube quality gate, Trivy dependency/IaC/secret/image gates | VERIFIED (builds #3 failure = gate working, #4/#7/#8 pass) |
| Zero-downtime deployment with automatic rollback | Helm `--wait`, `maxUnavailable: 0`, readiness probes, preStop, graceful shutdown, `scripts/deploy-k8s.sh` rollback | VERIFIED (9,532 requests, 0 errors) |
| Infrastructure as code | Terraform (VPC, EKS, RDS, ECR, IAM, KMS, S3, monitoring, Jenkins EC2) | VERIFIED (apply + no-drift plans) |
| Configuration management | Ansible roles for the Jenkins host, SonarQube, JCasC | VERIFIED (idempotent re-runs `changed=0`) |
| Monitoring, alerting, central logs | CloudWatch alarms → SNS → SQS; Budgets; ELK on EKS | VERIFIED except budget/email notifications |
| Cost control | suspend/resume scripts | VERIFIED (2026-10-19) |

### 2.4 Scope

In scope: one web application (React UI + Spring Boot REST API + MySQL), local Docker Compose and minikube
environments, one AWS environment (`dev`) in `ap-south-1`, single Jenkins controller, single NAT gateway,
HTTP only. Out of scope: user authentication/authorisation (the login page only navigates), HTTPS/domain,
multi-region, autoscaling policies (HPA / Cluster Autoscaler), payment, email delivery of alerts.

### 2.5 Main features

Application: dashboard KPIs (users, products, orders, revenue excluding cancelled, low-stock list), product
CRUD with computed stock status (`IN_STOCK` > 10, `LOW_STOCK` 1–10, `OUT_OF_STOCK` ≤ 0), user creation with
case-insensitive unique email, multi-line orders with atomic stock reservation, status changes with stock
restoration on cancel, consistent JSON errors with a request id, liveness and readiness endpoints.

Platform: immutable image tags, two quality/security gate types, Helm releases with history, automatic
rollback, readiness-gated traffic, PodDisruptionBudgets, KMS-encrypted Kubernetes Secrets, private RDS with
TLS-only connections, namespace-scoped Jenkins permissions, CloudWatch alarms with verified delivery,
budget guardrail, central logs with request tracing, one-command suspend/resume.

### 2.6 Technology stack (actual versions from the repository)

| Layer | Technology | Where |
|---|---|---|
| Frontend | React 18.3, React Router 7, Vite 8, Vitest 5, ESLint 9; served by nginx 1.30 (unprivileged) | `order-inventory-platform/frontend/package.json`, `Dockerfile` |
| Backend | Java 17, Spring Boot 4.1.1 (Web MVC, Data JPA, Validation, Flyway), Hibernate, HikariCP, JaCoCo | `backend/pom.xml` |
| Database | MySQL 8.4 (Compose: `mysql:8.4`; AWS: RDS MySQL 8.4.11 db.t3.micro); H2 for tests | `docker-compose.yml`, `terraform/main.tf` |
| Containers | Docker multi-stage builds, Docker Compose | `*/Dockerfile`, `docker-compose*.yml` |
| Orchestration | Amazon EKS 1.36, managed node group 2× t3.medium, Helm chart, AWS Load Balancer Controller 3.6.0 | `terraform/main.tf`, `helm/order-inventory/`, `scripts/install-lb-controller.sh` |
| IaC | Terraform 1.15.8, AWS provider ~> 5.0, S3 backend with native locking | `terraform/` |
| Config management | Ansible core 2.19 (run in a container), roles + JCasC | `ansible/` |
| CI/CD | Jenkins LTS on EC2 (Ubuntu 24.04), declarative `Jenkinsfile`, SCM polling | `Jenkinsfile`, `ansible/roles/jenkins*` |
| Quality / security | SonarQube 26.10 Community, Trivy 0.76, gitleaks (manual scans) | `Jenkinsfile`, `.trivyignore.yaml`, `.gitleaksignore` |
| AWS | VPC, NAT, ECR, EKS, RDS, ALB, EC2, IAM/IRSA, KMS, Secrets Manager, S3, CloudWatch, SNS, SQS, Budgets | `terraform/*.tf` |
| Logging | Elasticsearch/Kibana/Filebeat 8.19.5, ECS JSON logs | `k8s/logging/elk.yaml`, `order-inventory-platform/logging/` |

### 2.7 Why this is a DevOps project, not only a CRUD application

The application code is deliberately modest: of the 180 tracked files, 71 are application source and 109
are delivery, operations and documentation:
pipeline (`Jenkinsfile`), infrastructure (`terraform/`), configuration management (`ansible/`), packaging
(`Dockerfile`s, Helm chart), operations (`scripts/`), observability (`k8s/logging`, `terraform/monitoring.tf`)
and evidence (`docs/evidence`). The evaluated properties — zero downtime, automatic rollback, gated releases,
reproducible infrastructure, least privilege, cost control — are properties of the platform, and each is
backed by an executed test.

### 2.8 What makes it production-style

- Immutable, traceable artefacts (`<build>-<commit>` tags, IMMUTABLE ECR, OCI revision labels).
- Gates that actually stopped bad builds (build #3 failed on 5 HIGH IaC findings and was fixed).
- Health model separating liveness from readiness; graceful shutdown and drain timing.
- Secrets generated by machines, stored in Secrets Manager, KMS-encrypted in Kubernetes, never in Git.
- Private data tier, TLS-enforced DB connections, IMDSv2, non-root read-only containers.
- Remote, encrypted, versioned, locked Terraform state; drift checks after changes.
- Runbooks, alarms with verified delivery, recorded evidence for every claim.

### 2.9 "Microservices": an accurate description

The **application** is **not** a set of independent microservices. It is a **single Spring Boot service**
(a modular monolith with `users`, `products`, `orders` packages that share one MySQL schema and one
transaction boundary — order creation and stock deduction happen in the same database transaction) plus a
**separate frontend container** (static React files served by nginx). Two independently built, versioned,
scaled and health-checked containers are deployed behind a path-routing load balancer.

The **platform** is microservice-ready: each service has its own image repository, Deployment, Service,
probes, PDB and ALB target group, and the pipeline/Helm pattern would extend to more services. Say exactly
this if asked; splitting orders and inventory into separate services would require distributed transactions
or a saga pattern, which would weaken the overselling guarantee this project demonstrates.

### 2.10 Limitations and trade-offs (honest list)

| Limitation | Reason / trade-off |
|---|---|
| No real authentication; login page only navigates | not in scope; do not expose real data |
| HTTP only | no domain/ACM certificate; documented as accepted risk |
| Single NAT gateway, single-AZ Jenkins, single SonarQube | cost; not highly available |
| RDS single-AZ db.t3.micro, `skip_final_snapshot = true` | cost / clean lab teardown; production would use Multi-AZ, deletion protection, final snapshot |
| ELK on `emptyDir`, security disabled, single node | demo-sized; logs lost on node replacement; access only via port-forward |
| Polling instead of webhook (up to 5-minute delay) | Jenkins accepts traffic only from the admin /32 |
| Backend uses the RDS master user | simplicity; a least-privilege DB user is recommended |
| No autoscaling (HPA / Cluster Autoscaler) | fixed 2 replicas / 2 nodes |
| Concurrency test runs on H2, not MySQL | fast and isolated; the locking SQL is standard `SELECT … FOR UPDATE` |
| `ansible/run-playbook.sh` passes the two admin passwords to a local `node` process as arguments before streaming them to the container on stdin | brief local exposure in the workstation's process list (see [10-security.md](handbook/10-security.md)) |

### 2.11 Future improvements

HTTPS with ACM; real authentication (OIDC/Cognito); dedicated DB user with least privilege; Multi-AZ RDS
with deletion protection; HPA + Cluster Autoscaler/Karpenter; GitHub webhook through a restricted ingress or
GitHub Actions OIDC; External Secrets Operator instead of `create-db-secret.sh`; managed OpenSearch or
CloudWatch Container Insights instead of in-cluster ELK; VPC endpoints (ECR, S3, STS) to reduce NAT cost;
canary/blue-green with Argo Rollouts; SLO-based alarms and dashboards.

---

## 3. Component status matrix

| Component | Status | Evidence |
|---|---|---|
| Backend tests (29) and coverage | VERIFIED | `docs/TESTING.md`; Jenkins builds #4, #7, #8 (`docs/evidence/jenkins-github-*.txt`) |
| Frontend lint, tests (21), build | VERIFIED | `docs/TESTING.md`, Jenkins builds |
| Docker images, non-root, Compose acceptance (8/8) | VERIFIED | `docs/TESTING.md` |
| Helm chart + minikube acceptance (rollout/rollback/outage) | VERIFIED | `docs/evidence/k8s-acceptance-2026-10-18.txt` |
| Terraform infrastructure | VERIFIED | `docs/AWS_DEPLOYMENT.md`; no-drift plan 2026-10-19 |
| Terraform admin-IP update branch of resume | IMPLEMENTED; targeted plan VERIFIED 2026-10-25 (not applied) | §1.1 |
| Ansible configuration of Jenkins | VERIFIED | `docs/TESTING.md`, `docs/evidence/ansible-container-test-2026-10-18.txt` |
| Jenkins pipeline from GitHub (manual trigger) | VERIFIED | build #7 evidence |
| Jenkins pipeline triggered by a GitHub push (polling) | VERIFIED | build #8 evidence |
| GitHub webhook trigger | NOT IMPLEMENTED (by design) | `docs/TESTING.md` "Not yet verified" |
| SonarQube quality gate | VERIFIED | build evidence: `QUALITY GATE STATUS: PASSED` |
| Trivy gates | VERIFIED | build #3 failure, later passes |
| Zero downtime + automatic rollback on AWS | VERIFIED | `docs/evidence/aws-zero-downtime-2026-10-19.txt` |
| DB interruption behaviour on AWS | VERIFIED | `docs/evidence/aws-rds-interruption-2026-10-19.txt` |
| CloudWatch → SNS → SQS delivery | VERIFIED | `docs/TESTING.md` |
| AWS Budget notification | IMPLEMENTED BUT NOT VERIFIED (threshold never reached) | `docs/TESTING.md` |
| Email alert delivery | NOT IMPLEMENTED (no email subscribed) | `terraform/monitoring.tf` (`alert_email` empty) |
| ELK on EKS with request-id tracing | VERIFIED | `docs/evidence/elk-eks-2026-10-19.txt` |
| Kibana objects after resume | IMPLEMENTED BUT NOT VERIFIED | §1.2.6 |
| Suspend / resume / idempotent re-run | VERIFIED | `docs/AWS_DEPLOYMENT.md` |
| PowerShell wrappers | VERIFIED for `suspend --plan`; resume wrapper IMPLEMENTED BUT NOT VERIFIED (resume ran via Git Bash) | 2026-10-19 session |
| Git history secret removal | VERIFIED on a fresh clone; old SHAs on GitHub need Support purge (**BLOCKED** on GitHub Support) | `docs/SECURITY.md` |
| Root access key deactivation, MFA on admin user | BLOCKED (owner action) | `docs/SECURITY.md` "Current credential status" |
| HTTPS, authentication, autoscaling | NOT IMPLEMENTED | §2.10 |

## 4. Companion chapters (Parts 3–19)

Each chapter explains the real files; the [repository inventory](handbook/01-repository-inventory.md) lists
every tracked file, which chapter covers it and at what depth (line by line, block by block, or by category
for generated/third-party content), so the coverage can be checked.

1. [01 — Repository and file-by-file inventory](handbook/01-repository-inventory.md)
2. [02 — Frontend](handbook/02-frontend.md)
3. [03 — Backend](handbook/03-backend.md)
4. [04 — MySQL, RDS and Flyway](handbook/04-database.md)
5. [05 — Docker and Docker Compose](handbook/05-docker.md)
6. [06 — Terraform](handbook/06-terraform.md)
7. [07 — Ansible](handbook/07-ansible.md)
8. [08 — Jenkins and CI/CD](handbook/08-jenkins-cicd.md)
9. [09 — EKS, Kubernetes, Helm and ALB](handbook/09-kubernetes-helm-eks.md)
10. [10 — SonarQube, Trivy and security](handbook/10-security.md)
11. [11 — Monitoring and logging](handbook/11-monitoring-logging.md)
12. [12 — Suspend and resume, line by line](handbook/12-suspend-resume.md)
13. [13 — Architecture diagrams and request flows](handbook/13-diagrams.md)
14. [14 — Viva and cross-question bank](handbook/14-viva-question-bank.md)
15. [15 — Presentation scripts](handbook/15-presentation-scripts.md)
16. [16 — Glossary](handbook/16-glossary.md)
