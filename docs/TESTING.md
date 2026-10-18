# Testing and verification report

All results below were produced by actually running the listed commands on 2026-10-18
(Windows 11, Docker Desktop 29.5, minikube 1.38, Helm 4.2/4.3, Terraform 1.15.8, JDK 26 locally / 17–21 in
containers, Node 24). Raw outputs are in [`docs/evidence/`](evidence/).

Status legend: **VERIFIED** = executed and passed · **IMPLEMENTED, NOT VERIFIED** = exists, no execution
evidence · **BLOCKED** = needs access/approval.

## Application

| Check | Command | Result | Status |
|---|---|---|---|
| Backend tests (API integration, concurrency, failure paths, correlation, unit) | `mvn -B clean verify` | 29/29 passed; JaCoCo lines 70.97 % (484/682), branches 75 % | VERIFIED |
| Concurrency test detects overselling | lock removed temporarily → test fails; restored → passes | mutation check done | VERIFIED |
| Flyway migrations apply on an empty DB (H2) and Hibernate validates | part of `mvn verify` | V1, V2 applied | VERIFIED |
| Flyway on a real pre-existing MySQL volume | `docker compose up` on the old volume | baselined at 1, V2 applied, rows 4/4/3/3 unchanged (backup taken first) | VERIFIED |
| Flyway + demo seed on a fresh MySQL volume | compose acceptance (isolated project) | V1, V2, seed applied; 5 demo users | VERIFIED |
| Frontend lint | `npm run lint` | 0 errors, 0 warnings | VERIFIED |
| Frontend tests (API client, routing, pages, workflows, hook) | `npm run test:coverage` | 21/21 passed; lines 80 %, branches 67 % | VERIFIED |
| Frontend production build | `npm run build` | success | VERIFIED |
| npm dependencies | `npm audit` | 0 vulnerabilities | VERIFIED |

## Docker / Compose

| Check | Command | Result | Status |
|---|---|---|---|
| Images build from the repository | `docker compose build --pull`, Jenkins Docker Build stage | both build | VERIFIED |
| End-to-end functional test through nginx | `scripts/smoke-test.sh` | 20/20 | VERIFIED |
| Compose acceptance on a clean, isolated volume | `COMPOSE_PROJECT_NAME=oi-fresh scripts/compose-acceptance-test.sh` | 8/8: healthy start, smoke test, persistence across `down`/`up`, DB outage (ready 503, API 503, liveness 200) and automatic recovery, crash auto-restart (restart count 0→1), clean stop | VERIFIED |
| Non-root containers | `docker exec … id` | backend uid 10001, frontend uid 101 | VERIFIED |
| Security headers | `curl -I` | nosniff, DENY, no-cache index | VERIFIED |

## Kubernetes / Helm (minikube)

Methodology: an in-cluster curl pod requests `GET /api/products` through the frontend Service every 50 ms for
120 s during each release; every non-200 is a failure. Script: `scripts/k8s-acceptance-test.sh`; evidence:
[`evidence/k8s-acceptance-2026-10-18.txt`](evidence/k8s-acceptance-2026-10-18.txt).

| Scenario | Result | Status |
|---|---|---|
| Initial install + 20-check smoke test | passed | VERIFIED |
| Rolling update v1 → v2 | 1,898 requests, 0 failed | VERIFIED |
| Bad image release | deploy exit 1, auto-rollback to v2; 1,895 requests, 0 failed | VERIFIED |
| Release whose pods never become Ready (wrong DB credentials) | deploy exit 1, auto-rollback, working secret restored; 1,964 requests, 0 failed | VERIFIED |
| Database outage | all backend pods unready, 0 restarts; recovered automatically, data persisted (PVC) | VERIFIED |
| Pod loss | replacement Ready (2/2) | VERIFIED |
| Chart lint / render / schema | `helm lint --strict`; `helm template` + kubeconform strict (15 resources) | VERIFIED |
| Chart refuses missing or `latest` tag | `helm template` | VERIFIED |

Scope: proves Kubernetes/Helm behaviour; ALB target (de)registration timing needs EKS.

## CI/CD (Jenkins)

Local controller built from `ci/jenkins/Dockerfile` (pinned toolchain, configuration as code) with SonarQube
26.10 community; job runs the repository's `Jenkinsfile` from the committed state with `DEPLOY=false`.

| Build | Result | Notes |
|---|---|---|
| #1, #2 | FAILURE | environment issues found and fixed: Git "dubious ownership" on the mounted repo; image fixes (xz-utils, docker-cli) |
| #3 | SUCCESS (6m09s) | full CI path; evidence [`evidence/jenkins-local-build-3.txt`](evidence/jenkins-local-build-3.txt) |
| #4 | SUCCESS (3m25s) | latest code: 29 tests, coverage recorded with sources, SonarQube gate PASSED (backend + frontend), Trivy gates passed, images built and scanned |

These local runs used `DEPLOY=false`. The full pipeline including deployment was then run on the
Jenkins EC2 host — see "AWS deployment" below. Jenkinsfile syntax was additionally validated with Jenkins'
declarative linter.

## Infrastructure and configuration management

| Check | Result | Status |
|---|---|---|
| `terraform fmt -check -recursive`, `terraform validate` | clean | VERIFIED |
| `terraform plan` full profile | 77 to add, 0 to change, 0 to destroy | VERIFIED (plan only) |
| `terraform plan` learning profile | 62 to add, 0 to change, 0 to destroy | VERIFIED (plan only) |
| Variable guard: EKS API `0.0.0.0/0` rejected | plan fails with "Do not open the EKS API to 0.0.0.0/0." | VERIFIED |
| Trivy IaC scan (Terraform, Helm, Dockerfiles), HIGH/CRITICAL, both profiles | 0 findings beyond the 4 documented exceptions in `.trivyignore` | VERIFIED |
| `terraform apply` (full profile + generated secrets + DB tuning) | 90 + 6 created, then 1 in-place change; `terraform plan` afterwards: no changes | VERIFIED |
| Ansible syntax + `ansible-lint` (production profile) | clean | VERIFIED |
| Ansible apply on Ubuntu 24.04 (systemd container) | 29 ok, 0 failed; second run `changed=0`; Jenkins active, `/login` 200; toolchain versions match pins | VERIFIED ([evidence](evidence/ansible-container-test-2026-10-18.txt)) |
| Ansible against the real Jenkins EC2 host (incl. SonarQube + Jenkins configuration as code) | first run 49 ok / 24 changed / 0 failed; repeat runs `changed=0`; Jenkins survives restart | VERIFIED |

## Logging and monitoring

| Check | Result | Status |
|---|---|---|
| Filebeat ships only app containers; backend ECS fields parsed | verified by Elasticsearch queries | VERIFIED |
| ILM retention policy (delete after 7 days) installed | `GET _ilm/policy/order-inventory-logs` | VERIFIED |
| Kibana objects import (data view, 4 saved searches, dashboard) | `kibana-setup.sh`: 6 objects, success | VERIFIED |
| Trace a failed order by `requestId` | one id returned the nginx access line and the backend `Order rejected …` event | VERIFIED |
| CloudWatch alarm → SNS → SQS delivery | `set-alarm-state` test: message received with expected alarm/state/metric; alarm restored | VERIFIED |
| Real alarm on real metrics | `rds-freeable-memory-low` fired: swap was growing (1 → 35 MB) under MySQL 8.4 defaults on the 1 GiB db.t3.micro. Parameter group tuned (buffer pool 256 MB, performance_schema off — verified live via a client pod; swap back to ~4 MB). The remaining 40–60 MB free is RDS OS overhead present even with 0 connections, so the threshold was recalibrated to 25 MiB and a SwapUsage > 200 MiB alarm added; all 13 alarms OK | VERIFIED (genuine finding) |
| AWS Budget | $350, ACTUAL 80 % / FORECASTED 100 % → SNS; threshold not reached | IMPLEMENTED, NOT VERIFIED (cannot be triggered without spend) |
| ELK on EKS | pods Ready (read-only root fs); failed order traced by `requestId` with Kubernetes metadata; 7-day ILM; DB password in 0 documents | VERIFIED |

## Security scans

| Scan | Tool / version | Result |
|---|---|---|
| Backend image (Alpine 3.24.2 + `app.jar`) | Trivy 0.76.0 (Jenkins build #4) | 0 vulnerabilities, all severities |
| Frontend image (Alpine 3.24.2) | Trivy 0.76.0 | 0 vulnerabilities |
| Dependencies (`pom.xml`, `package-lock.json`) | Trivy 0.76.0 fs | 0 vulnerabilities |
| IaC misconfiguration | Trivy config | 0 beyond documented exceptions |
| Secrets in the working tree / each commit | gitleaks 8.28, Trivy secret scanner | clean |
| Secrets in **public GitHub history** | gitleaks on a fresh clone after the 2026-10-19 push | clean (0 occurrences of the destroyed RDS password); old SHAs need a GitHub Support purge |
| Code quality | SonarQube 26.10 | quality gate PASSED (backend, frontend) |

Before remediation the images had 11 (backend) and 68 (frontend) HIGH/CRITICAL findings, including a
Spring Framework RCE fixed only in Spring 7 → resolved by upgrading to Spring Boot 4.1, nginx 1.30, patched
Tomcat/Jackson and `apk upgrade`.

## AWS deployment (ap-south-1, 2026-10-18/19)

Details and resource inventory: [AWS_DEPLOYMENT.md](AWS_DEPLOYMENT.md).

### Jenkins on EC2 (configured by Ansible; builds #1–#6 from the host's Git mirror, #7+ from GitHub)

| Build | Result | Cause / notes |
|---|---|---|
| #1 | FAILURE at checkout | Git "dubious ownership" on the mirror (owned by `ubuntu`, read by `jenkins`) → `safe.directory` added in the `git_mirror` role |
| #2 | FAILURE at Deploy (exit 126) | all CI stages passed and images were pushed (`2-06f7acc`); scripts lacked the executable bit in Git (Windows) → `git update-index --chmod=+x` |
| #3 | FAILURE at Dependency & IaC Scan | **gate worked**: 5 HIGH findings in the new `k8s/logging/elk.yaml` → fixed (read-only root fs, non-root ES/Kibana, path-scoped Filebeat exception) |
| **#4** | **SUCCESS** (6m15s) | commit `bf7450d`: 29 backend tests, frontend lint/tests/build, SonarQube gate PASSED (backend + frontend), Trivy dependency/IaC/secret/image gates, Helm lint, images `4-bf7450d` pushed to ECR, Helm deploy (2/2 + 2/2), image-tag verification, in-cluster readiness, 8 checks through the ALB |
| #5 | SUCCESS | commit `eaf6380` (mirror), images `5-eaf6380` |
| #6 | FAILURE at Deploy ("context canceled") | Jenkins was restarted mid-deploy by the Ansible run that switched the job to GitHub; the pipeline rolled back to revision 8 automatically |
| **#7** | **SUCCESS** | first build **cloned from GitHub** (`ca5c22c`), manual trigger; all gates, `7-ca5c22c` deployed ([evidence](evidence/jenkins-github-build-7-2026-10-19.txt)) |
| **#8** | **SUCCESS** | **started by SCM polling of GitHub** after a push (`18a2bc6`); `8-18a2bc6` deployed, 8 ALB checks ([evidence](evidence/jenkins-github-poll-build-8-2026-10-19.txt)) |

### Application through the public ALB

| Check | Result | Status |
|---|---|---|
| ALB + target groups | internet-facing, 2 public subnets; backend (`/api/health`) and frontend (`/healthz`) targets healthy | VERIFIED |
| Full read/write smoke test (`scripts/smoke-test.sh`) against RDS | 20/20 | VERIFIED |
| Flyway on RDS | V1 and V2 applied, two replicas coordinated by Flyway's lock, no baseline marker | VERIFIED |
| Network exposure | ALB: only 80 open; RDS private (10.0.22.34), 3306 unreachable from the internet, SG = EKS cluster SG only; Jenkins 22/8080 only from the admin /32; SonarQube not reachable externally | VERIFIED |
| ECR | immutable tags, scan on push: 0 findings for `4-bf7450d` | VERIFIED |

### Zero downtime, rollback and failure tests on AWS

Client on the workstation, through the public ALB; every non-200 counts.
Evidence: [aws-zero-downtime](evidence/aws-zero-downtime-2026-10-19.txt), [aws-rds-interruption](evidence/aws-rds-interruption-2026-10-19.txt).

| Scenario | Requests | Non-200 | Outcome |
|---|---|---|---|
| Rolling release 4-bf7450d → 2-06f7acc | 1,712 | 0 | 113 s |
| Rolling release 2-06f7acc → 4-bf7450d | 1,702 | 0 | 108 s |
| Non-existent image | 1,982 | 0 | deploy exit 1, automatic Helm rollback |
| Pods never Ready (wrong DB credentials) | 2,394 | 0 | deploy exit 1, rollback, working secret restored |
| Controlled restart of both deployments | 1,742 | 0 | 103 s |
| **Total** | **9,532** | **0** | |
| RDS reboot (database interruption) | 88 samples | 3× 503 on `/api/products` (~1 s) | liveness and frontend 100 % 200; 0 pod restarts; data intact |

## Not yet verified

1. GitHub **webhook** trigger: not configured (Jenkins is restricted to the admin /32); GitHub-triggered builds
   use SCM polling every 5 minutes, which is verified (build #8).
2. Budget notification at a real threshold (requires actual spend).
3. Email delivery of alerts (no email subscribed; delivery verified through the SQS audit subscription).
4. HTTPS (no domain/ACM certificate in this project).
