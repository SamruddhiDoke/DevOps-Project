# Part 19 — Glossary and concept guide

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md)

Columns: definition · analogy · how it applies here · related file/command · a likely viva question.

## Networking and AWS

| Term | Definition | Analogy | In this project | File / command | Viva question |
|---|---|---|---|---|---|
| VPC | a private, isolated network in AWS | a gated campus | `10.0.0.0/16` | `aws_vpc.main` | "What is your VPC CIDR?" |
| Subnet | a slice of the VPC in one Availability Zone | a building on the campus | 2 public, 2 private, 2 database | `aws_subnet.*` | "Why three tiers?" |
| Availability Zone | an isolated data-centre group in a region | two separate buildings with own power | ap-south-1a, 1b | `terraform.tfvars` | "Why two AZs?" |
| Route table | rules saying where traffic for an address range goes | road signs | public→IGW, private→NAT, database→none | `aws_route_table.*` | "Why can't RDS reach the internet?" |
| Internet gateway | VPC's door to the internet | main gate | for public subnets | `aws_internet_gateway.igw` | — |
| NAT gateway | lets private resources make outbound connections only | a one-way exit turnstile | nodes pull images through it | `aws_nat_gateway.nat` | "Why keep NAT while suspended?" |
| Elastic IP | a static public IPv4 address | a permanent phone number | NAT gateway IP | `aws_eip.nat` | "Why does Jenkins' IP change?" (it has no EIP) |
| Security group | a stateful firewall attached to resources | a guest list at a door | RDS allows only the cluster SG; Jenkins only your /32 | `aws_security_group.*` | "How is RDS protected?" |
| CIDR /32 | a range containing exactly one IP address | one specific house | admin access | `admin.auto.tfvars` | "What does /32 mean?" |
| IAM role / policy | identity with permissions that services can assume / a permission document | a staff badge / the badge's access list | Jenkins role, node role, LBC role | `jenkins.tf`, `main.tf` | "Why roles instead of keys?" |
| Least privilege | grant only what is needed | a key that opens one room | Jenkins: 2 ECR repos, 1 cluster, 1 bucket, 1 namespace | `jenkins_ecr_push` etc. | "Show least privilege." |
| IRSA / OIDC provider | Kubernetes service accounts assume IAM roles via an OIDC trust | a visitor pass issued by reception | LBC and EBS CSI roles | `aws_iam_openid_connect_provider.eks` | "How does the controller get AWS permissions?" |
| IMDSv2 | session-token-protected instance metadata service | a door needing a fresh code | required on Jenkins | `metadata_options` | "Why IMDSv2?" |
| KMS / CMK | managed encryption keys / a key you control | a bank vault key | Kubernetes Secrets, SNS, SQS | `kms.tf` | "Why a customer-managed key?" |
| Secrets Manager | managed storage for secrets | a safe-deposit box | RDS, Jenkins, SonarQube passwords | `order-inventory/*` | "Where is the DB password?" |
| ECR | AWS container image registry | a warehouse for packaged goods | 2 IMMUTABLE repos, scan on push | `aws_ecr_repository.*` | "Why immutable?" |
| RDS | managed relational database | a hosted database with a caretaker | MySQL 8.4 db.t3.micro | `aws_db_instance.mysql` | "Why managed DB?" |
| PITR | point-in-time recovery from backups + logs | rewinding a recording | 7-day window | `backup_retention_period` | "How would you restore yesterday's data?" |
| ALB | layer-7 HTTP load balancer | a receptionist routing visitors by request | created from the Ingress | `ingress.yaml` | "How is it created?" |
| Target group | the set of backends an ALB rule sends to, with health checks | a department's staff list | backend and frontend TGs (pod IPs) | — | "What is target-type ip?" |
| CloudWatch alarm | metric threshold that changes state and triggers actions | a smoke detector | 13 alarms | `monitoring.tf`, `create-alb-alarms.sh` | "What does INSUFFICIENT_DATA mean?" |
| SNS / SQS | pub/sub notification topic / message queue | a loudspeaker / a mailbox | alerts → audit queue | `aws_sns_topic.alerts`, `aws_sqs_queue.alerts_audit` | "How did you verify alerts?" |
| AWS Budgets | cost thresholds with notifications | a spending alert on a card | $350, 80 % actual / 100 % forecast | `aws_budgets_budget.monthly` | "Does a budget stop spending?" (no) |

## Containers and orchestration

| Term | Definition | Analogy | In this project | File / command | Viva question |
|---|---|---|---|---|---|
| Image | read-only template of a container's filesystem + start command | a recipe-packed meal kit | backend, frontend | `Dockerfile` | "Image vs container?" |
| Container | isolated process started from an image | a cooked meal from the kit | in Compose and pods | `docker compose up` | "Container vs VM?" |
| Multi-stage build | build in one stage, copy only results to the final stage | cook in the kitchen, serve only the plate | Maven/Node builders → JRE/nginx | Dockerfiles | "Why?" |
| Registry | stores and serves images | warehouse | ECR | `docker push` | — |
| Immutable tag | a tag that can never point to another image | a serial number | `8-18a2bc6` | Jenkinsfile `IMAGE_TAG` | "Why not latest?" |
| Kubernetes | container orchestrator | an air-traffic controller | EKS 1.36 | `kubectl` | — |
| Control plane / node | the cluster's brain / the machines running pods | head office / branch offices | AWS-managed / 2 × t3.medium | — | "Why does EKS cost with 0 nodes?" |
| Pod | smallest deployable unit (one or more containers) | one worker at a desk | backend/frontend pods | `kubectl get pods` | — |
| Deployment / ReplicaSet | manages versions / keeps N identical pods | a manager / a team of identical workers | 2 + 2 replicas | `backend.yaml` | "Difference?" |
| Service | stable name/IP for a set of ready pods | a department phone number | `backend:8080`, `frontend:80` | `kubectl get svc` | "How do pods find each other?" |
| Ingress | HTTP routing rules into the cluster | a building directory | `/api` → backend, `/` → frontend | `ingress.yaml` | "Ingress vs Service?" |
| ConfigMap / Secret | non-secret / secret configuration for pods | a notice board / a sealed envelope | `backend-config` / `mysql-secret` | templates | "How are credentials injected?" |
| Probe (startup/liveness/readiness) | health checks deciding start-up, restart and traffic | "are you awake / alive / ready for customers?" | `/api/health`, `/api/health/ready`, `/healthz` | `backend.yaml` | "Readiness vs liveness?" |
| Resource requests/limits | guaranteed / maximum CPU and memory | reserved seat / seat-belt limit | backend 250m/512Mi → 500m/1Gi | `values.yaml` | "Why limits?" |
| Rolling update | replace pods gradually | changing train carriages one at a time while it runs | maxSurge 1, maxUnavailable 0 | `values.yaml` | "How is downtime avoided?" |
| PodDisruptionBudget | minimum pods kept during voluntary disruptions | minimum staff on duty | minAvailable 1 | `pdb.yaml` | — |
| DaemonSet | one pod per node | a security guard on every floor | Filebeat | `elk.yaml` | — |
| Helm chart / release / revision | package of templates / installed instance / numbered version of it | app installer / installed app / app version history | `helm/order-inventory`, release `order-inventory` | `helm history` | "How do you roll back?" |
| Namespace | a scope for names and permissions | a department | `order-inventory`, `logging` | `k8s/namespace.yaml` | "Why is Jenkins limited to one namespace?" |
| Security context | process privileges of a pod/container | the rules of a visitor badge | non-root, read-only rootfs, no capabilities | templates | — |

## Delivery, quality and operations

| Term | Definition | Analogy | In this project | File / command | Viva question |
|---|---|---|---|---|---|
| Infrastructure as Code | infrastructure defined in versioned files | architectural blueprints | Terraform | `terraform/` | — |
| Terraform state | Terraform's record of managed resources | an inventory ledger | S3, encrypted, locked | `backend.tf` | "Why sensitive?" |
| State drift | real infrastructure differs from code/state | the ledger no longer matches the shelves | stopped Jenkins public IP | `terraform plan` | "How do you detect drift?" |
| `ignore_changes` | tell Terraform not to manage an attribute | "don't correct this note in the ledger" | node desired size, Jenkins AMI/public-IP flag | `main.tf`, `jenkins.tf` | "Why needed? Risks?" |
| Configuration management | automated, repeatable server configuration | a checklist robot | Ansible roles | `ansible/` | — |
| Idempotency | repeating an operation has no extra effect | pressing a lift button twice | Ansible `changed=0`; scripts re-run safely | `run-playbook.sh`, `*-evaluation.sh` | "Prove idempotency." |
| CI / CD | continuous integration / continuous delivery-deployment | quality-control line / automatic shipping | Jenkinsfile stages | `Jenkinsfile` | "Difference?" |
| Quality gate | pass/fail conditions on code analysis | an exam pass mark | SonarQube "PASSED" | Code Quality stage | — |
| Static analysis | analysing code without running it | proof-reading | SonarQube | — | — |
| Vulnerability scanning | matching components to known CVEs | checking food against recall lists | Trivy fs/image, ECR scan | Jenkinsfile | "Does 0 findings mean secure?" |
| Misconfiguration scanning | checking IaC against security rules | building-code inspection | `trivy config` | `.trivyignore.yaml` | — |
| Secrets management | generating, storing and delivering secrets safely | a key-management office | Terraform → Secrets Manager → K8s Secret | `create-db-secret.sh` | — |
| Database migration | versioned schema change script | renovation plan with numbered steps | Flyway V1, V2 | `db/migration/` | "Why Flyway?" |
| Rollback | return to the previous good version | undo | `helm rollback` | `deploy-k8s.sh` | "How automatic is it?" |
| Zero downtime | no failed user requests during changes | changing tyres while the car drives | 9,532 requests, 0 errors | evidence file | "How proven?" |
| Observability | understanding a system from its outputs (metrics, logs) | a dashboard and black box | CloudWatch + ELK | — | — |
| Correlation / request id | one id attached to all logs of a request | a parcel tracking number | `X-Request-Id`, MDC | `RequestIdFilter.java` | "How do you trace a request?" |
| Structured logging (ECS) | logs as JSON fields following the Elastic Common Schema | a form instead of free text | backend logs | `LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs` | — |
| ILM | index lifecycle management (rollover, delete) | automatic archive shredding | delete after 7 days | `ilm-policy.json` | — |
| Recovery manifest | record of what to restore | a packing list | `evaluation-manifest.json` | suspend/resume | "What is in it?" |
| Suspend / resume | stop billable compute while keeping data, then restore | putting a shop in standby rather than demolishing it | evaluation scripts | `scripts/*-evaluation.sh` | "Why not destroy?" |
| Pessimistic lock | lock a row before changing it | reserving the last ticket while paying | `SELECT … FOR UPDATE` | `ProductRepository.findByIdForUpdate` | "How is overselling prevented?" |
| Transaction | all-or-nothing group of DB operations | a bank transfer | `@Transactional` services | `OrderService` | — |
| Graceful shutdown | finish in-flight work before exiting | serving the customers in the queue before closing | 20 s | `application.properties` | — |
