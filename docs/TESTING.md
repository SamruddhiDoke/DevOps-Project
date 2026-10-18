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

Deployment stages (ECR push, Helm deploy to EKS, ALB health check, post-failure rollback) were skipped
by design (`DEPLOY=false`) → **BLOCKED** until AWS is provisioned. Their logic is the same
`scripts/deploy-k8s.sh` verified on minikube. Jenkinsfile syntax was additionally validated with Jenkins'
declarative linter.

## Infrastructure and configuration management

| Check | Result | Status |
|---|---|---|
| `terraform fmt -check -recursive`, `terraform validate` | clean | VERIFIED |
| `terraform plan` full profile | 77 to add, 0 to change, 0 to destroy | VERIFIED (plan only) |
| `terraform plan` learning profile | 62 to add, 0 to change, 0 to destroy | VERIFIED (plan only) |
| Variable guard: EKS API `0.0.0.0/0` rejected | plan fails with "Do not open the EKS API to 0.0.0.0/0." | VERIFIED |
| Trivy IaC scan (Terraform, Helm, Dockerfiles), HIGH/CRITICAL, both profiles | 0 findings beyond the 4 documented exceptions in `.trivyignore` | VERIFIED |
| `terraform apply` / real AWS resources | not run (cost approval required) | BLOCKED |
| Ansible syntax + `ansible-lint` (production profile) | clean | VERIFIED |
| Ansible apply on Ubuntu 24.04 (systemd container) | 29 ok, 0 failed; second run `changed=0`; Jenkins active, `/login` 200; toolchain versions match pins | VERIFIED ([evidence](evidence/ansible-container-test-2026-10-18.txt)) |
| Ansible against the real EC2 host | needs the instance | BLOCKED |

## Logging and monitoring

| Check | Result | Status |
|---|---|---|
| Filebeat ships only app containers; backend ECS fields parsed | verified by Elasticsearch queries | VERIFIED |
| ILM retention policy (delete after 7 days) installed | `GET _ilm/policy/order-inventory-logs` | VERIFIED |
| Kibana objects import (data view, 4 saved searches, dashboard) | `kibana-setup.sh`: 6 objects, success | VERIFIED |
| Trace a failed order by `requestId` | one id returned the nginx access line and the backend `Order rejected …` event | VERIFIED |
| CloudWatch alarms / SNS / Budget delivery | defined in Terraform; not created | BLOCKED |

## Security scans

| Scan | Tool / version | Result |
|---|---|---|
| Backend image (Alpine 3.24.2 + `app.jar`) | Trivy 0.76.0 (Jenkins build #4) | 0 vulnerabilities, all severities |
| Frontend image (Alpine 3.24.2) | Trivy 0.76.0 | 0 vulnerabilities |
| Dependencies (`pom.xml`, `package-lock.json`) | Trivy 0.76.0 fs | 0 vulnerabilities |
| IaC misconfiguration | Trivy config | 0 beyond documented exceptions |
| Secrets in the working tree / each commit | gitleaks 8.28, Trivy secret scanner | clean |
| Secrets in **current public history** | gitleaks | 6 findings (one destroyed RDS password) — remediation prepared, needs force-push approval |
| Code quality | SonarQube 26.10 | quality gate PASSED (backend, frontend) |

Before remediation the images had 11 (backend) and 68 (frontend) HIGH/CRITICAL findings, including a
Spring Framework RCE fixed only in Spring 7 → resolved by upgrading to Spring Boot 4.1, nginx 1.30, patched
Tomcat/Jackson and `apk upgrade`.

## Not yet verified

These require the approved AWS deployment:

1. `terraform apply` (full or learning profile) and post-apply `terraform plan` showing no drift.
2. Ansible against the Jenkins EC2 host; Jenkins job with `DEPLOY=true`.
3. Images pushed to ECR (immutability, scan on push), Helm deploy to EKS through Jenkins.
4. ALB provisioning by the Load Balancer Controller (IRSA), public smoke test, zero-downtime test through the ALB.
5. RDS TLS enforcement with the real endpoint; KMS-encrypted Secrets.
6. CloudWatch alarm → SNS email delivery (e.g. `aws cloudwatch set-alarm-state` test), Budget notification.
7. CI report upload to S3.
8. Teardown and the post-teardown checklist (docs/RUNBOOKS.md §8).
