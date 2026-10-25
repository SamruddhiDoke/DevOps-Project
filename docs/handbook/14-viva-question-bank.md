# Part 17 — Viva and cross-question bank

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md)

Format: **Q** — question; **Say** — a short answer in simple spoken English; **Deeper** — detail if the
evaluator follows up. Level: (B) beginner, (I) intermediate, (A) advanced. Every answer matches the code in
this repository; file references are given so you can show the evidence.

## A. The hard cross-questions first

**Q (A): Why did you choose EKS instead of ECS?**
Say: "I wanted the deployment to be portable and to learn Kubernetes properly: the same Helm chart runs on
minikube and on EKS, and I tested rollouts and rollbacks locally before AWS."
Deeper: Kubernetes gives readiness/liveness/startup probes, rolling-update control (`maxSurge`/`maxUnavailable`),
PDBs, Helm revisions, DaemonSets (Filebeat) and the AWS Load Balancer Controller. Trade-off: EKS has a
control-plane fee (≈ $0.10/h) and more complexity; ECS would be cheaper and simpler for two services.

**Q (B): Why is RDS private?**
Say: "Only the backend needs the database. It sits in subnets with no route to the internet, has no public IP,
and its security group accepts MySQL only from the EKS cluster."
Deeper: `aws_route_table.database` has no routes, `publicly_accessible = false`, SG rule from
`cluster_security_group_id`, TLS required (`require_secure_transport=1`), encrypted storage. Tested: port 3306
unreachable from the internet.

**Q (B): Why use both Terraform and Ansible?**
Say: "Terraform creates cloud resources through the AWS API; Ansible installs and configures software inside
the Jenkins server over SSH. Each is idempotent in its own area."
Deeper: `terraform/jenkins.tf` creates instance, SG, IAM role, passwords; `ansible/roles/*` install JDK,
Maven, Node, Docker, Trivy, Helm, kubectl, Terraform, AWS CLI, Jenkins, SonarQube and configure Jenkins as code.

**Q (B): What is the difference between a Deployment and a ReplicaSet?**
Say: "A ReplicaSet keeps a fixed number of identical pods running. A Deployment manages ReplicaSets: for a new
version it creates a new ReplicaSet and shifts pods over gradually, and it can go back."
Deeper: `kubectl -n order-inventory get rs` shows one ReplicaSet per pod-template version
(`revisionHistoryLimit: 10`).

**Q (B): Difference between readiness and liveness probes?**
Say: "Liveness asks 'is the process healthy or should Kubernetes restart it?'; readiness asks 'can this pod
take traffic right now?'. Our liveness `/api/health` does not touch the database; readiness
`/api/health/ready` does. So a database outage takes pods out of traffic without restarting them."
Deeper: plus a startup probe (up to 180 s) so slow JVM starts are not killed. Tested in `FailurePathWebTest`,
the Compose acceptance test and the AWS RDS reboot (0 restarts).

**Q (I): What happens when a pod crashes?**
Say: "Kubernetes restarts the container; if the pod or its node is gone, the ReplicaSet creates a new pod.
While it is not ready it gets no traffic, and the other replica keeps serving."
Deeper: two replicas per service, PDB `minAvailable: 1` for voluntary disruptions, `restartPolicy: Always`
with back-off. Verified "pod loss → replacement Ready" on minikube.

**Q (I): What happens when all worker nodes are scaled to zero?**
Say: "All pods stop because there is nowhere to run them. The control plane keeps every object — Deployments,
Services, Secrets, Helm history — so when nodes come back, Kubernetes recreates the pods automatically."
Deeper: in the suspend script the apps are scaled to 0 first and the ALB removed first, so nothing is
orphaned; resume scales nodes to 2 and redeploys with Helm.

**Q (B): Why does EKS still cost money when the nodes are stopped?**
Say: "AWS runs the Kubernetes control plane for us around the clock and bills it per cluster-hour, about ten
cents an hour, independent of the number of nodes."

**Q (I): How does the ALB get created from an Ingress?**
Say: "The AWS Load Balancer Controller runs in the cluster, watches Ingress objects with class `alb`, and calls
the AWS API to create the ALB, the listener rules for `/api` and `/`, and one target group per Service."
Deeper: IRSA role `order-inventory-aws-lbc-role` (policy `k8s/iam_policy.json`), annotations in `values.yaml`
(`internet-facing`, `target-type: ip`, health-check settings, deregistration delay 20 s), public subnets
discovered by the `kubernetes.io/role/elb` tag.

**Q (A): What happens if the database becomes unavailable during an order?**
Say: "Nothing half-done is saved, because the whole order is one transaction. The user gets a 503 'database
temporarily unavailable, retry', and if the outage lasts, Kubernetes stops sending traffic to the backend
pods until the database is back — without restarting them."
Deeper: Hikari `connection-timeout=5000` → `CannotCreateTransactionException` → `GlobalExceptionHandler` 503;
a broken connection mid-transaction → rollback. Measured on AWS: 3 × 503 during a ~1 s RDS interruption,
0 restarts (`docs/evidence/aws-rds-interruption-2026-10-19.txt`).

**Q (A): How does the system prevent overselling?**
Say: "When an order is created, the backend locks each product row it needs — `SELECT … FOR UPDATE` — inside one
transaction, checks the stock and deducts it before committing. A second buyer has to wait for the lock and then
sees the new stock, so only one of them can take the last unit."
Deeper: products locked in ascending id order to avoid deadlocks; duplicate lines share one locked object;
`CHECK (stock_quantity >= 0)` in V2 as a database-level guard; `OrderConcurrencyTest`: 8 buyers, stock 3 →
exactly 3 orders (mutation-checked). Lock wait timeout → 409 "retry". Limitation: the test runs on H2.

**Q (B): Why use Flyway?**
Say: "The database schema is versioned like code. Each change is a numbered SQL file that runs once, in order,
automatically at startup, identically in tests, locally and on RDS; Hibernate only validates it."

**Q (B): Why immutable image tags?**
Say: "Each build gets a unique tag `<build>-<commit>` and the registry refuses to overwrite it, so a tag always
means exactly one tested image. Rollback is just deploying an older tag."
Deeper: ECR `image_tag_mutability = "IMMUTABLE"`; Helm helper fails on missing tag or `latest`;
`deploy-k8s.sh` refuses `latest`; OCI revision labels link images to commits.

**Q (A): How does Jenkins roll back a bad release?**
Say: "Before deploying, the deploy script records the last good Helm revision. Helm waits until the new pods
are Ready; if they are not, the script rolls back to that revision and fails the build. If the release becomes
Ready but fails the checks afterwards, the pipeline's failure handler rolls back too."
Deeper: `scripts/deploy-k8s.sh` (`helm upgrade --wait`, `helm rollback $PREV_REVISION`), Jenkinsfile `post
{ failure }`. Verified on AWS: non-existent image and never-Ready release both rolled back automatically with
0 failed user requests.

**Q (A): How do you prove zero downtime?**
Say: "I ran a load generator through the real public ALB during two version changes, a bad image, a release
that could never become ready, and a restart. Every response was recorded: 9,532 requests, zero non-200."
Deeper: `scripts/aws-zero-downtime-test.sh`; evidence `docs/evidence/aws-zero-downtime-2026-10-19.txt`.
Mechanisms: `maxUnavailable: 0`, `maxSurge: 1`, readiness gating, preStop 10 s, graceful shutdown 20 s,
ALB deregistration delay 20 s, PDBs.

**Q (I): What is the difference between Terraform state and the actual AWS state?**
Say: "The state file is Terraform's memory of what it created. AWS is the truth. `terraform plan` refreshes the
state from AWS and shows the differences against my code."
Deeper: state in S3 (encrypted, versioned, locked); contains sensitive values (generated passwords) → never
in Git. Drift example: stopped Jenkins reports no public IP.

**Q (A): Why was `ignore_changes` required for the Jenkins instance?**
Say: "When Jenkins is stopped it has no public IP, and AWS reports `associate_public_ip_address = false`.
Terraform saw that as a difference and planned to destroy and recreate Jenkins. That attribute only matters at
creation, so I told Terraform to ignore it — same for the AMI, so a new Ubuntu image never replaces the server."
Deeper: found in a plan while suspended, nothing was applied; afterwards the plan showed no resource changes.
Limitation: ignored attributes are no longer managed (deliberate changes need `-replace`).

**Q (A): Why is deleting a password from the latest commit insufficient?**
Say: "Git keeps every old version. Anyone can open the old commit and read it. You must rewrite history and,
more importantly, rotate the credential."
Deeper: `git filter-repo` rewrite, force-with-lease push (approved), fresh-clone verification; GitHub still
serves old SHAs until purged; the leaked password's database was destroyed and never reused.

**Q (I): What happens if the resume script stops halfway through?**
Say: "Run it again. Every step checks the current state first — for example it only starts RDS if it is
stopped and only deploys if the release is not already running — so it continues where it stopped."
Deeper: measured idempotent re-run: 55 s, no changes. Failures print `FAILED in stage`, the reason and
diagnostic commands.

**Q (B): Why does the ALB URL change after resume?**
Say: "Suspend deletes the Ingress so AWS deletes the load balancer to save cost. Resume creates a new Ingress,
so AWS creates a new load balancer with a new DNS name. The script prints the new URL."

**Q (A): What would you improve if this were a real production deployment?**
Say: "HTTPS with a certificate, real authentication, Multi-AZ RDS with deletion protection, autoscaling,
GitHub webhooks or OIDC-based CI, managed logging, and canary releases."
Deeper: see handbook §2.11.

**Q (A): Which parts are production-style and which are simplified?**
Say: "Production-style: immutable tagged images, gated pipeline, zero-downtime rolling updates with automatic
rollback, infrastructure as code with remote state, private database with TLS, least-privilege IAM, alarms,
central logs. Simplified: no login, HTTP only, single NAT, single small database, demo-sized ELK, no
autoscaling, fixed node count."

## B. Project overview and design

| # | Q | Say |
|---|---|---|
| 1 (B) | What does the application do? | Manages users, products and orders; reserves stock when an order is placed and returns it when cancelled. |
| 2 (B) | What is the DevOps part? | Automated build, test, quality and security gates, container packaging, deployment to Kubernetes on AWS without downtime, infrastructure as code, configuration management, monitoring, logging and cost control. |
| 3 (I) | Is it microservices? | The platform is microservice-ready; the application is one Spring Boot service plus a separate frontend container. Splitting orders and inventory would need distributed transactions. |
| 4 (I) | Why one region and two AZs? | Two AZs are required by EKS and give resilience for nodes and the ALB; one region keeps cost and complexity low. |
| 5 (A) | What are the single points of failure? | One NAT gateway, single-AZ RDS, one Jenkins host, single-node Elasticsearch. Documented trade-offs for cost. |

## C. Frontend

| # | Q | Say |
|---|---|---|
| 1 (B) | Why React and Vite? | Component-based UI; Vite is fast, maintained, produces hashed static assets and shares config with Vitest. |
| 2 (B) | How does the UI call the backend? | `fetch('/api/…')` on the same origin; the ALB/nginx/Vite proxy routes `/api` to the backend. |
| 3 (I) | Build-time vs runtime config? | `VITE_*` is compiled into the bundle; nginx `BACKEND_URL` is substituted when the container starts. |
| 4 (I) | Why no secrets in the frontend? | Everything in the bundle is downloadable by every user. |
| 5 (I) | How are errors shown? | `api.js` turns non-2xx responses into errors with the backend's message or field details; pages show toasts. |
| 6 (A) | Why reject a 200 HTML response from `/api`? | It means `/api` was routed to the SPA fallback; failing loudly exposes routing mistakes. |
| 7 (I) | What do frontend tests check? | Rendering, client validation, which request is sent and how responses/errors are displayed, with a fetch mock that fails on unexpected requests (21 tests). |

## D. Java and Spring Boot

| # | Q | Say |
|---|---|---|
| 1 (B) | What does `@RestController` do? | Marks a class whose methods handle HTTP requests and return JSON. |
| 2 (B) | What is dependency injection here? | Spring creates the services/repositories and passes them into constructors. |
| 3 (I) | What does `@Transactional` do? | Wraps the method in a DB transaction; commit on success, rollback on runtime exceptions. |
| 4 (I) | Why DTOs? | Stable API contract, validation at the edge, no accidental exposure of entity internals. |
| 5 (I) | How is validation done? | Bean Validation annotations on request DTOs + `@Valid`; errors become 400 with field details. |
| 6 (A) | Why constructor injection and `final` fields? | Explicit, immutable dependencies; easy to test. |
| 7 (A) | What is `open-in-view=false`? | No DB session during response rendering; prevents hidden lazy-loading queries. |
| 8 (I) | How is a request id generated and used? | `RequestIdFilter` reuses a safe `X-Request-Id` or creates a UUID, puts it in the MDC and the response; error bodies contain it; logs contain it. |

## E. REST and HTTP status codes

| Code | Used for in this API |
|---|---|
| 200 | successful GET/PUT |
| 201 | created user/product/order |
| 204 | product deleted |
| 400 | validation error, malformed JSON, wrong type, insufficient stock, cancelled order change, duplicate email |
| 404 | missing user/product/order, unknown route |
| 405 | wrong HTTP method |
| 409 | conflict with existing data (FK/unique) or lock timeout (retry) |
| 503 | database temporarily unavailable; readiness down |
| 500 | unexpected error (generic message) |

Q (I): Why PUT for status and not PATCH? — Say: "The client sends the complete new value of the status
sub-resource `/orders/{id}/status`; PUT replaces it." (PATCH would also be defensible.)

## F. SQL, MySQL, transactions, concurrency

| # | Q | Say |
|---|---|---|
| 1 (B) | What tables exist? | users, products, orders, order_items with foreign keys. |
| 2 (I) | Why `DECIMAL(10,2)` for prices? | Exact money arithmetic. |
| 3 (I) | Why store price in order_items? | So past orders keep the price paid even if the product price changes. |
| 4 (A) | Pessimistic vs optimistic locking? | Pessimistic: lock the row before changing it (used here). Optimistic: detect conflicts at commit with a version column and retry. |
| 5 (A) | Isolation level? | MySQL default REPEATABLE READ; correctness comes from locking reads (`FOR UPDATE`) that see the latest committed data. |
| 6 (A) | What is a deadlock and how is it avoided? | Two transactions waiting for each other's locks; avoided by locking products in ascending id order. |
| 7 (I) | Why CHECK constraints if the API validates? | Defence in depth against bugs or manual SQL. |

## G. Docker and Compose

| # | Q | Say |
|---|---|---|
| 1 (B) | Container vs VM? | A container is an isolated process sharing the host kernel; a VM runs its own OS. |
| 2 (B) | Why multi-stage builds? | Small runtime images without build tools. |
| 3 (I) | How do containers find each other in Compose? | Docker DNS resolves service names (`mysql`, `backend`) on the shared network. |
| 4 (I) | Why non-root? | Limits damage if compromised; required by `runAsNonRoot`. |
| 5 (I) | What survives `docker compose down`? | The named MySQL volume; only `down -v` deletes it. |

## H. Git and GitHub

| # | Q | Say |
|---|---|---|
| 1 (I) | What is `--force-with-lease`? | A force push that only succeeds if the remote is still at the commit you expect, so you never overwrite someone else's new work. |
| 2 (I) | Why `.gitattributes eol=lf`? | Shell scripts with Windows line endings fail in Linux containers. |
| 3 (I) | Why was build #2 exit 126? | Scripts were not executable in Git (Windows); fixed with `git update-index --chmod=+x`. |

## I. Terraform

| # | Q | Say |
|---|---|---|
| 1 (B) | What is IaC? | Infrastructure described in versioned code and created by a tool, reproducibly. |
| 2 (B) | `plan` vs `apply`? | Plan shows the changes; apply performs them. |
| 3 (I) | Why remote state + locking? | Shared, durable, encrypted; no concurrent corruption. |
| 4 (I) | What is a provider lock file? | Pins provider versions and checksums for reproducibility. |
| 5 (A) | What does `-target` do and why is it risky? | Limits a plan to some resources; can leave the rest inconsistent, so it is only used for the controlled admin-IP update with a guard. |
| 6 (A) | What are variable validations/preconditions? | Rules that fail the plan, e.g. no `0.0.0.0/0` for EKS/Jenkins access. |

## J. Ansible

| # | Q | Say |
|---|---|---|
| 1 (B) | What is a playbook / role? | A playbook maps hosts to roles; a role is a reusable set of tasks, handlers, defaults, templates. |
| 2 (I) | What is idempotency? | Re-running changes nothing if the host is already correct (`changed=0`, verified). |
| 3 (I) | What is JCasC? | Jenkins configured from a YAML file instead of clicking: users, credentials, job, global env. |
| 4 (A) | How are secrets protected in Ansible? | Streamed on stdin into the controller container, `no_log` on tasks, files `root:jenkins 0640`, placeholders in JCasC. |

## K. Jenkins and CI/CD

| # | Q | Say |
|---|---|---|
| 1 (B) | What is CI vs CD? | CI: build and test every change; CD: automatically release tested changes to the environment. |
| 2 (I) | How is the pipeline triggered? | SCM polling of GitHub every 5 minutes (verified by build #8). |
| 3 (I) | Why no webhook? | Jenkins accepts traffic only from the admin IP. |
| 4 (I) | Where do AWS credentials come from? | The EC2 instance role; nothing stored in Jenkins. |
| 5 (A) | What stops a vulnerable image reaching production? | Trivy image gate before the ECR push; ECR scan on push as a second look. |
| 6 (A) | What happens after a resume? | Jenkins polls and builds any commit pushed while it was off. |

## L. SonarQube and Trivy

| # | Q | Say |
|---|---|---|
| 1 (B) | What does SonarQube do? | Static analysis for bugs, vulnerabilities, smells, duplication, coverage; the quality gate decides pass/fail. |
| 2 (I) | What does Trivy scan? | Dependencies, IaC misconfigurations, secrets and images. |
| 3 (I) | Why `--ignore-unfixed`? | Unfixable CVEs cannot be resolved by rebuilding; gating on them would block every release. |
| 4 (A) | Example of the gate working? | Build #3 failed on 5 HIGH IaC findings in the ELK manifest. |

## M. AWS services

| # | Q | Say |
|---|---|---|
| 1 (B) | What is a VPC / subnet? | A private network / a range of it in one AZ. |
| 2 (B) | Public vs private subnet? | Public has a route to the internet gateway; private goes out through NAT and cannot be reached from outside. |
| 3 (I) | What does the NAT gateway do? | Lets private nodes reach the internet (ECR, AWS APIs) without being reachable. |
| 4 (I) | What is IRSA? | IAM roles for Kubernetes service accounts via the cluster's OIDC provider. |
| 5 (I) | What is KMS used for? | Encrypting Kubernetes Secrets and the SNS topic/SQS queue. |
| 6 (I) | What is in Secrets Manager? | RDS master credentials, Jenkins and SonarQube admin passwords (generated by Terraform). |
| 7 (I) | What is IMDSv2? | Token-based instance metadata access; blocks SSRF credential theft. |
| 8 (A) | Why is the deployer user not admin? | PowerUser + IAM read + IAM write scoped to `order-inventory-*`. Least privilege; never root. |
| 9 (I) | What is S3 used for? | Terraform state (bootstrap bucket) and CI reports (30-day expiry). |

## N. Monitoring, logging, cost, recovery

| # | Q | Say |
|---|---|---|
| 1 (B) | What alarms exist? | 5 RDS, 2 Jenkins, 1 node CPU, 1 NAT (Terraform) + 4 ALB (script). |
| 2 (I) | How did you verify alerts? | Forced an alarm; message arrived in the SQS queue subscribed to SNS. |
| 3 (I) | Did monitoring find a real problem? | Yes: RDS memory/swap on db.t3.micro → parameter tuning + recalibrated alarm. |
| 4 (I) | How do you trace a failed request? | Use the `requestId` from the error response in Kibana. |
| 5 (I) | How do you control cost? | Suspend/resume scripts, budget alerts, small instance types, lifecycle policies, log retention. |
| 6 (A) | What is your recovery strategy for data? | RDS 7-day automated backups with point-in-time restore (restore itself not exercised), versioned state bucket, immutable images. |
| 7 (A) | RDS stop limit? | AWS auto-starts a stopped instance after 7 days; re-run suspend. |
