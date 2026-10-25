# Part 11 — Jenkins and CI/CD

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md)

## 8.1 Where Jenkins runs and how it is configured

| Item | Value |
|---|---|
| Host | EC2 `i-03288b455e674765e`, t3.large, Ubuntu 24.04, public subnet, 30 GB encrypted gp3 |
| Access | `http://<public-ip>:8080`, only from the admin /32 (security group); SSH 22 from the same /32 |
| Configuration | Ansible roles + Jenkins Configuration as Code (`ansible/roles/jenkins_casc/templates/casc.yaml.j2`); see [07-ansible.md](07-ansible.md) |
| Job | `order-inventory` (pipeline from SCM), Git remote `https://github.com/SamruddhiDoke/DevOps-Project.git`, branch `*/main`, script `Jenkinsfile`, trigger `pollSCM('H/5 * * * *')` |
| AWS credentials | **none stored**: the EC2 instance role (`order-inventory-jenkins-role`) via IMDSv2 |
| Kubernetes permissions | EKS access entry: `AmazonEKSEditPolicy` in namespace `order-inventory` only |
| SonarQube | container on the same host, `127.0.0.1:9000`; token credential `sonarqube-token` |
| Persistence across stop/start | `/var/lib/jenkins` (jobs, build history, plugins) and the SonarQube Docker volumes are on the root EBS volume, which is kept when the instance stops; verified: after the resume, build history (#1–#7) was intact and build #8 ran |

**Why polling, not a webhook:** a GitHub webhook needs GitHub's servers to reach Jenkins on port 8080, but the
security group admits only the administrator's /32. Opening it to GitHub's hook IP ranges (or the internet) was
deliberately not done. Polling means Jenkins asks GitHub every ~5 minutes ("H" spreads the minute to avoid
load spikes) whether `main` has a new commit — outbound traffic only. Verified: build #8 shows "Started by an
SCM change" after the push of `18a2bc6` (`docs/evidence/jenkins-github-poll-build-8-2026-10-19.txt`).

## 8.2 Pipeline-level settings (`Jenkinsfile` lines 10–43)

| Setting | Meaning |
|---|---|
| `agent any` | run on the controller's executor (2 executors configured) |
| `parameters { booleanParam DEPLOY=true; booleanParam FULL_SMOKE_TEST=false }` | `DEPLOY=false` = CI-only run (local Jenkins); `FULL_SMOKE_TEST=true` runs the read/write smoke test against production (creates and cancels a test order). Parameters appear in the UI ("Build with Parameters") after the first run of this Jenkinsfile |
| `environment { AWS_REGION, APP_DIR, EKS_CLUSTER, K8S_NAMESPACE, HELM_RELEASE, REPORTS, TRIVY_CACHE_DIR }` | shared constants; Trivy's vulnerability DB is cached under `JENKINS_HOME` between builds |
| `options { disableConcurrentBuilds(); buildDiscarder(logRotator(numToKeepStr: '20')); timeout(60 min); timestamps() }` | never two deployments at once; keep 20 builds; abort hung builds; timestamped log lines |

## 8.3 Every stage

| Item | Explanation |
|---|---|
| **Stage** | **1. Checkout** |
| Purpose | get the exact commit and compute the immutable image tag |
| Commands | `checkout scm`; `GIT_SHORT=$(git rev-parse --short=7 HEAD)`; `IMAGE_TAG=${BUILD_NUMBER}-${GIT_SHORT}`; check that `backend/pom.xml`, both Dockerfiles, `package-lock.json`, `Chart.yaml`, `scripts/deploy-k8s.sh` exist; recreate `reports/` |
| Inputs | GitHub `main` (the revision polling detected) |
| Outputs | workspace, `IMAGE_TAG` e.g. `8-18a2bc6` |
| Failure conditions | GitHub unreachable, missing required file |
| Recovery | check network/GitHub; the log shows `Checking out Revision …` |
| Viva | "How is the image tag derived?" → build number + short commit: unique and traceable to source |

| Item | Explanation |
|---|---|
| **Stage** | **2. Environment Check** |
| Purpose | fail fast if the agent's toolchain is incomplete |
| Commands | `java -version`, `mvn -version`, `node --version` (+ assert ≥ 20.19), `npm`, `docker`, `trivy`, `helm`, `kubectl`, `aws --version` |
| Failure | a tool missing or Node too old |
| Recovery | re-run the Ansible playbook (installs pinned versions) |

| Item | Explanation |
|---|---|
| **Stage** | **3. Backend Tests** |
| Commands | `mvn -B clean verify` in `order-inventory-platform/backend`; `post always`: `junit(… surefire-reports/*.xml, allowEmptyResults: false)` (a run with **zero tests fails**), `recordCoverage` (JaCoCo), copy the coverage report into `reports/` |
| Outputs | test results and coverage in the Jenkins UI; JaCoCo XML for SonarQube |
| Failure | any of the 29 tests fails, compilation error |
| Recovery | open the test report; reproduce locally with `mvn verify` |
| Viva | "Why `allowEmptyResults: false`?" → a misconfiguration that runs no tests must not look green |

| Item | Explanation |
|---|---|
| **Stage** | **4. Frontend Build** |
| Commands | `npm ci --no-audit --no-fund`; `npm run lint` (0 warnings allowed); `npx vitest run --coverage --reporter=default --reporter=junit --outputFile.junit=reports/junit.xml`; `npm run build`; post: `junit` (no empty results), copy coverage |
| Failure | lint warning/error, failing test, build error |

| Item | Explanation |
|---|---|
| **Stage** | **5. Code Quality** (SonarQube) |
| Condition | `when { expression { env.SONAR_HOST_URL } }` — skipped with a message if SonarQube is not configured (set globally by JCasC on AWS) |
| Commands | `withCredentials([string(credentialsId: 'sonarqube-token', variable: 'SONAR_TOKEN')])`; backend: `mvn … sonar-maven-plugin:5.8.0.7211:sonar -Dsonar.host.url=… -Dsonar.qualitygate.wait=true -Dsonar.qualitygate.timeout=300`; frontend: `sonar-scanner` with the same wait flags |
| Outputs | analysis in SonarQube; `QUALITY GATE STATUS: PASSED` in the log |
| Failure | quality gate FAILED (e.g. new bugs, coverage on new code below threshold), timeout |
| Recovery | open SonarQube via SSH tunnel (`ssh -L 9000:127.0.0.1:9000 ubuntu@<jenkins-ip>`), fix issues |
| Viva | "What is a quality gate?" → a pass/fail rule set on the analysis; `qualitygate.wait=true` makes the build wait for and obey it |

| Item | Explanation |
|---|---|
| **Stage** | **6. Dependency & IaC Scan** (Trivy) |
| Commands | (a) `trivy fs --scanners vuln` table report of all dependencies → `reports/trivy-dependencies.txt`; (b) gate: `--severity CRITICAL --exit-code 1`; (c) `trivy config --severity HIGH,CRITICAL --exit-code 1 --ignorefile .trivyignore.yaml --tf-vars terraform/environments/full.tfvars` over Terraform, Helm, Dockerfiles, Kubernetes YAML (skips `node_modules`, `.terraform`, `k8s/testing`) → `reports/trivy-iac.txt`; (d) `trivy fs --scanners secret --exit-code 1` |
| Failure | a CRITICAL dependency CVE, a new HIGH/CRITICAL misconfiguration, a secret in the working tree |
| Real example | build #3 on EC2 failed here: 5 HIGH findings in the new `k8s/logging/elk.yaml` → fixed by hardening the pods and one path-scoped exception (`docs/TESTING.md`) |

| Item | Explanation |
|---|---|
| **Stage** | **7. Helm Lint** |
| Commands | `helm lint helm/order-inventory --strict --set image.tag=${IMAGE_TAG} --set image.registry=example.invalid`; `helm template … > reports/rendered-manifests.yaml` |
| Purpose | the chart renders and is valid before any image is built; the rendered manifests are archived for review |

| Item | Explanation |
|---|---|
| **Stage** | **8. Docker Build** |
| Commands | for backend and frontend: `docker build --pull --label org.opencontainers.image.revision=${GIT_COMMIT} --label org.opencontainers.image.version=${IMAGE_TAG} -t order-inventory-${svc}:${IMAGE_TAG} ${APP_DIR}/${svc}` |
| Notes | `--pull` always fetches the newest base image (security fixes); labels make an image traceable to its commit |

| Item | Explanation |
|---|---|
| **Stage** | **9. Image Scan** |
| Commands | full table report per image; gate: `trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1` |
| Why `--ignore-unfixed` | a finding without an available fix cannot be resolved by rebuilding; gating on it would block all releases. Fixable HIGH/CRITICAL findings fail the build |
| Result | build #7/#8: 0 findings (Alpine 3.24.2) |

| Item | Explanation |
|---|---|
| **Stage** | **10. AWS Identity Check** (only if `DEPLOY`) |
| Commands | `aws sts get-caller-identity` → `AWS_ACCOUNT_ID`, `ECR_REGISTRY=<account>.dkr.ecr.ap-south-1.amazonaws.com`; `aws eks describe-cluster … --query cluster.status` must be `ACTIVE` |
| Failure | instance role missing, cluster not ACTIVE (e.g. while suspended) |

| Item | Explanation |
|---|---|
| **Stage** | **11. Push Images to ECR** |
| Commands | `aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_REGISTRY` (short-lived token, from the instance role); `docker tag` + `docker push` both images with `${IMAGE_TAG}` |
| Note | runs **after** all gates — only tested and scanned images reach the registry. ECR is IMMUTABLE: pushing an existing tag fails |

| Item | Explanation |
|---|---|
| **Stage** | **12. Configure Kubernetes** |
| Commands | `aws eks update-kubeconfig`; `kubectl auth can-i patch deployments -n order-inventory`; `kubectl get deployments -n order-inventory` |
| Note | proves the namespace-scoped permission before deploying; Jenkins reaches the private API endpoint |

| Item | Explanation |
|---|---|
| **Stage** | **13. Deploy to EKS** |
| Commands | `env.DEPLOY_STARTED = 'true'`; `ROLLOUT_TIMEOUT=5m ./scripts/deploy-k8s.sh ${ECR_REGISTRY} ${IMAGE_TAG}` (§8.5) |
| Outputs | new Helm revision; pods of the new version Ready; `.deploy/previous-revision` |
| Failure | pods not Ready within 5 min → the script **rolls back** to the previous good revision and exits 1 |
| Real example | build #6: Jenkins was restarted by an Ansible run during this stage ("context canceled"); the pipeline's `post` rolled back to revision 8 |

| Item | Explanation |
|---|---|
| **Stage** | **14. Kubernetes Verification** |
| Commands | `kubectl get pods,svc,ingress -o wide`; for both deployments read `.spec.template.spec.containers[0].image` and require it to end in `:${IMAGE_TAG}` |
| Purpose | proves the cluster actually runs the image this build produced |

| Item | Explanation |
|---|---|
| **Stage** | **15. Application Health Check** |
| Commands | in-cluster: `kubectl run health-check-${BUILD_NUMBER} --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- curl -fsS http://backend:8080/api/health/ready`; read the ALB hostname from the Ingress (retry 30 × 10 s); wait until `http://$ALB_HOST/api/health` answers (new DNS names take minutes); then `SMOKE_READ_ONLY=1 ./scripts/smoke-test.sh` (8 checks) or the full 20-check test when `FULL_SMOKE_TEST`; save the hostname to `reports/alb-host.txt` |
| How Jenkins finds the endpoint | from the Ingress status at run time — never hard-coded, so it works after the ALB is recreated |
| Failure | readiness not UP, no ALB hostname, smoke check fails → `post failure` rollback |

| Item | Explanation |
|---|---|
| **Stage** | **16. Deployment Summary** |
| Output | build, commit, image tags, URL, rollback command |

### `post` section

- `failure`: if `DEPLOY_STARTED`, read `.deploy/previous-revision` and `helm rollback order-inventory <rev> --wait`
  — covers a release that became Ready but **failed the post-deploy checks** (deploy-k8s.sh already covers
  releases that never become Ready). Prints pods.
- `always`: `archiveArtifacts reports/**`; if deploying and `CI_REPORTS_BUCKET` is set, `aws s3 cp --recursive`
  to `s3://<bucket>/order-inventory/<build>/` (non-fatal); remove local images and `docker image prune -f`
  (never touches ECR or the cluster).

Artifacts per build: backend and frontend coverage, Trivy dependency/IaC/image reports, rendered manifests,
JUnit results, ALB host.

## 8.4 Trace of one commit (real: `18a2bc6`, build #8, 2026-10-19 UTC)

1. `git push` to GitHub `main` (`ca5c22c..18a2bc6`).
2. Within ≤ 5 minutes the poll detects the change → **"Started by an SCM change"**.
3. Checkout `Revision 18a2bc6…` from `https://github.com/SamruddhiDoke/DevOps-Project.git`; tag `8-18a2bc6`.
4. 29 backend tests pass (21:05:12); SonarQube gates PASSED for backend (21:06:21) and frontend (21:07:04).
5. Trivy gates pass; images built, scanned, pushed to ECR as `order-inventory-{backend,frontend}:8-18a2bc6`.
6. `deploy-k8s.sh` → `helm upgrade` → Helm revision 14 (rolling update: one new pod at a time, old pods keep serving).
7. "Release healthy": backend 2, frontend 2, both images `…:8-18a2bc6` (21:11:20).
8. In-cluster readiness `{"database":"UP","status":"UP"}`; "All 8 read-only checks passed against
   http://k8s-orderinv-…-1122521152.ap-south-1.elb.amazonaws.com" (21:11:36). `Finished: SUCCESS`.

Evidence: `docs/evidence/jenkins-github-poll-build-8-2026-10-19.txt`. Helm revision history around it
(from the evaluation logs): 11 = build #7, 12 = first suspend (Ingress disabled), 13 = resume test, **14 =
build #8**, 15 = second suspend; the next resume creates 16.

## 8.5 `scripts/deploy-k8s.sh` (line by line)

```bash
REGISTRY="${1:?usage…}"; TAG="${2:?usage…}"; shift 2
NAMESPACE="${K8S_NAMESPACE:-order-inventory}"; RELEASE="${RELEASE:-order-inventory}"; TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
```
Required registry and tag; remaining arguments are passed to Helm (e.g. `-f values-minikube.yaml`).

```bash
[ "$TAG" != "latest" ] || { echo "Refusing to deploy the mutable tag 'latest'" >&2; exit 1; }
[ "$(kubectl auth can-i create deployments -n "$NAMESPACE" 2>/dev/null)" = yes ] || { …exit 1; }
kubectl -n "$NAMESPACE" get secret "${DB_SECRET:-mysql-secret}" >/dev/null || { …exit 1; }
```
Guards: never `latest` (also enforced in the chart helper); permission check that works with Jenkins'
namespace-only access (reading the Namespace object itself would need cluster scope); DB Secret must exist.

```bash
PREV_REVISION="$(helm -n "$NAMESPACE" history "$RELEASE" -o json 2>/dev/null | node -e '…pick the last "deployed" (else "superseded") revision…' || true)"
echo "PREV_REVISION=${PREV_REVISION}" > "$STATE_DIR/previous-revision"
```
Records the **last known-good revision** before changing anything (used by this script's rollback and the
Jenkinsfile's `post failure`). Empty on the first install.

```bash
if helm upgrade --install "$RELEASE" "$CHART" --namespace "$NAMESPACE" \
     --set image.registry="$REGISTRY" --set image.tag="$TAG" --wait --timeout "$TIMEOUT" "$@"; then
  for d in backend frontend; do kubectl -n "$NAMESPACE" rollout status "deployment/$d" --timeout=60s; done
  …print deployments…; exit 0
fi
```
`upgrade --install` installs or upgrades; `--wait` makes Helm wait until all Deployments have their new pods
**Ready** (readiness probes passing) — otherwise the command fails after the timeout. `rollout status` double-checks.

```bash
echo "Deployment of ${TAG} failed (pods not Ready within ${TIMEOUT})." >&2
kubectl get pods …; kubectl get events … | tail -15
if [ -n "$PREV_REVISION" ]; then helm -n "$NAMESPACE" rollback "$RELEASE" "$PREV_REVISION" --wait --timeout "$TIMEOUT"; …
else echo "No previous revision (first install); leaving resources in place for diagnosis."; fi
exit 1
```
On failure: print diagnostics, **roll back** to the recorded revision and exit 1 so the pipeline fails. Because
`maxUnavailable: 0`, the old pods were never removed while the new ones were failing, so users saw no errors
(measured: scenarios C and D, 4,376 requests, 0 failures).

## 8.6 `scripts/smoke-test.sh` (what the checks are)

`request()` uses curl to call `BASE_URL + path`, storing status and body; `expect` compares the status;
`json` extracts a field with Node. The run id `smoke-<epoch>-<random>` makes all test data unique, so the test
can run repeatedly against a shared environment.

- Always: `GET /` contains `<div id="root">`; `GET /products` (SPA deep link) 200; `/api/health` UP;
  `/api/health/ready` database UP.
- Read-only mode (`SMOKE_READ_ONLY=1`, used by the pipeline): list products/users/orders 200; unknown API
  route 404 → **8 checks**.
- Full mode: create user (201), duplicate email with different case (400), get user; create product with
  stock 5 (`LOW_STOCK`), update stock to 20, invalid product (400); create order of 3 (201, total 37.5), stock
  17, order of 999 (400), cancel (200), stock back to 20, reopen cancelled (400), delete referenced product
  (409); non-numeric id (400), missing order (404), unknown route (404) → **20 checks**.

## 8.7 Immutable tags and rollback

- Each build pushes `<build>-<commit>`; ECR refuses to overwrite a tag; the chart refuses `latest`. A tag
  therefore always identifies one exact, scanned image and the commit it came from.
- With `latest`, "what is running?" and "roll back to what?" have no reliable answer: the same name points to
  different images over time, nodes may cache an old `latest`, and a rollback might redeploy the broken image.
- Rollback options: automatic (`deploy-k8s.sh`, Jenkinsfile `post`), manual `helm -n order-inventory rollback
  order-inventory [revision]`, or redeploy any older tag: `./scripts/deploy-k8s.sh <registry> 7-ca5c22c`.

## 8.8 Local CI (`ci/`)

`ci/start-local-ci.sh` generates passwords into `ci/.env` (git-ignored), starts SonarQube
(`127.0.0.1:19000`), replaces its factory password, creates an analysis token, builds and starts a Jenkins
image (`ci/jenkins/Dockerfile`: Jenkins 2.580.1 LTS + the same pinned toolchain + plugins + JCasC). The job
reads the repository mounted read-only at `/repo` (`ALLOW_LOCAL_CHECKOUT` enabled only for this local,
single-user controller) and defaults to `DEPLOY=false`. Used for local builds #1–#4 (`docs/TESTING.md`,
`docs/evidence/jenkins-local-build-3.txt`).

## 8.9 Build history on AWS (from `docs/TESTING.md`)

| Build | Result | Lesson |
|---|---|---|
| #1 | failed at checkout | Git "dubious ownership" → `safe.directory` |
| #2 | failed at deploy (exit 126) | scripts lacked the executable bit in Git (Windows) → `git update-index --chmod=+x` |
| #3 | failed at IaC scan | the security gate worked (5 HIGH findings) |
| #4, #5 | success | full pipeline incl. EKS deploy |
| #6 | failed at deploy | Jenkins restarted mid-build by Ansible; automatic rollback |
| #7 | success | first checkout from GitHub (manual trigger) |
| #8 | success | first build triggered by a GitHub push (polling) |

## 8.10 Troubleshooting failed builds

| Symptom | Where to look / fix |
|---|---|
| Checkout fails | network, GitHub availability, repo URL in the job configuration (JCasC) |
| Tests fail | JUnit report in the build; reproduce locally |
| Quality gate failed | SonarQube UI through the SSH tunnel |
| Trivy gate failed | `reports/trivy-*.txt` artefacts; update base image/dependency or add a justified, narrow exception |
| ECR push denied | instance role policy; tag already exists (immutable) |
| `kubectl auth can-i` = no | EKS access entry / namespace |
| Deploy timeout + rollback | `kubectl -n order-inventory get events`, `kubectl logs` of the new pods (image pull error, readiness failing, DB secret) |
| ALB checks fail | `kubectl get ingress`, target health, Load Balancer Controller logs |
| Build stuck waiting | `options timeout` aborts at 60 min; check `disableConcurrentBuilds` queue |

## 8.11 Viva questions

| Question | Answer |
|---|---|
| How does a commit reach production? | §8.4: push → poll → tests → quality gate → security gates → images → ECR → Helm rolling update → verification → (rollback on failure). |
| How does Jenkins roll back a bad release? | `deploy-k8s.sh` records the last good Helm revision, runs `helm upgrade --wait`, and on failure runs `helm rollback` to it; the Jenkinsfile `post failure` does the same for releases that fail the later checks. |
| How do you prove zero downtime? | Continuous requests through the public ALB during releases, failed releases and restarts: 9,532 requests, 0 non-200 (`docs/evidence/aws-zero-downtime-2026-10-19.txt`). |
| Why no AWS keys in Jenkins? | The EC2 instance role provides temporary credentials via IMDSv2; nothing to leak or rotate. |
| Why not a webhook? | Jenkins is not reachable from GitHub by design (admin /32 only); polling is outbound-only. Trade-off: up to ~5 min delay. |
| What happens if two builds run at once? | They cannot: `disableConcurrentBuilds()`. |
| What does Jenkins do after a resume? | It polls GitHub and builds any commit pushed while it was stopped. |
| Difference between CI and CD here? | CI = stages 1–9 (build, test, analyse, scan) on every commit; CD = stages 10–15 (publish and deploy to EKS automatically, with verification and rollback). |
