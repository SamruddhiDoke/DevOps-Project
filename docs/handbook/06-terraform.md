# Part 9 — Terraform: every file and every resource

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md) · Files in `terraform/`.

Terraform describes the desired AWS infrastructure in HCL files. `terraform plan` compares that description
with the **state** (Terraform's record of what it created) refreshed against the real AWS APIs, and shows the
differences; `terraform apply` makes them real. In this project the main stack manages **102 resources**
(`docs/AWS_DEPLOYMENT.md`), plus 5 in the bootstrap stack.

Standard commands (from `terraform/`, profile exported, `admin.auto.tfvars` last so your real IP wins over the
placeholder in the profile file):

```bash
export AWS_PROFILE=order-inventory AWS_REGION=ap-south-1
terraform init                                          # downloads providers, connects to the S3 backend
terraform fmt -check -recursive && terraform validate   # formatting + static validation
terraform plan -var-file=environments/full.tfvars -var-file=admin.auto.tfvars   # read-only diff
```

Never run `apply` or `destroy` to "demonstrate" something; a plan is enough to explain behaviour.

## 6.1 Files and variables

### `backend.tf`

```hcl
terraform { backend "s3" {
  bucket = "order-inventory-tfstate-038215676861"   # created by terraform/bootstrap
  key    = "order-inventory/terraform.tfstate"      # object path of the state
  region = "ap-south-1"
  encrypt      = true                               # server-side encryption of the state object
  use_lockfile = true                               # S3-native locking (Terraform >= 1.10): a .tflock object
} }
```
Remote state lets the scripts (`tfout` in `scripts/lib/evaluation-common.sh`), Jenkins and any laptop read the
same state. **Locking** prevents two `apply`s at the same time (the second waits/fails instead of corrupting
state). The bucket name is not a secret.

### `bootstrap/main.tf` — the chicken-and-egg

The state bucket must exist before the main stack can use it, so a tiny separate stack (with **local** state,
containing no secrets) creates it once: `aws_s3_bucket.state` (name includes the account id → globally
unique), `aws_s3_bucket_versioning` (every state version kept → recover from a bad apply),
`aws_s3_bucket_server_side_encryption_configuration` (AES256), `aws_s3_bucket_public_access_block` (all four
blocks on), `aws_s3_bucket_policy.state_tls_only` (deny any request with `aws:SecureTransport = false`).
`default_tags` add `Project`, `ManagedBy`, `Purpose` to everything.

### `main.tf` header

```hcl
required_version = ">= 1.10.0"                          # S3 native locking needs 1.10+
required_providers { aws = "~> 5.0", tls = "~> 4.0", random = "~> 3.6" }   # "~>" = allow minor/patch updates only
provider "aws" { region = var.aws_region
  default_tags { tags = { Project = var.project_name, Environment = var.environment, ManagedBy = "Terraform" } } }
data "aws_caller_identity" "current" {}                # account id for ARNs/policies
locals {
  eks_public_access_cidrs = length(var.eks_public_access_cidrs) > 0 ? var.eks_public_access_cidrs : var.admin_cidr_blocks
  cluster_name = "${var.project_name}-eks"   # order-inventory-eks
  app_namespace = "order-inventory"
}
```
*Stale comment:* lines 18–19 still say "State is local by default … backend.tf.example"; the S3 backend in
`backend.tf` is what is actually used.

`default_tags` is why the scripts can find project resources by tag (e.g. the NAT gateway with
`tag:Project=order-inventory`) and why Cost Explorer can group costs by project.

`.terraform.lock.hcl` pins the exact provider versions and checksums chosen at `init` so every machine uses the
same provider build.

### `variables.tf` (inputs and guardrails)

| Variable | Default | Notes |
|---|---|---|
| `aws_region` | `ap-south-1` | |
| `project_name`, `environment` | `order-inventory`, `dev` | name prefix, tags |
| `vpc_cidr` | `10.0.0.0/16` | 65,536 addresses |
| `availability_zones` | `["ap-south-1a","ap-south-1b"]` | two AZs (EKS requires subnets in ≥ 2 AZs) |
| `public_subnet_cidrs` / `private_subnet_cidrs` / `database_subnet_cidrs` | `10.0.1.0/24, 10.0.2.0/24` / `10.0.11.0/24, 10.0.12.0/24` / `10.0.21.0/24, 10.0.22.0/24` | three tiers |
| `eks_version` | `1.36` | description warns that extended-support versions cost 6× more per hour |
| `eks_public_access_cidrs` | `[]` (→ admin CIDRs) | **validation:** must not contain `0.0.0.0/0` |
| `node_instance_types`, `node_desired_size`, `node_min_size`, `node_max_size` | `t3.medium`, 2, 1, 3 | the full profile overrides min to **0** for suspension |
| `db_engine_version`, `db_instance_class`, `db_username`, `db_backup_retention_days` | `8.4`, `db.t3.micro`, `admin`, 7 | 8.0 would be in paid extended support |
| `create_jenkins` | `true` | learning profile sets `false` |
| `admin_cidr_blocks` | `[]` | **validation:** no `0.0.0.0/0`, and required when Jenkins is created |
| `jenkins_instance_type`, `jenkins_key_name` | `t3.medium`, `UniversalKey` | full profile uses `t3.large` (Jenkins + SonarQube) |
| `monthly_budget_usd`, `log_retention_days`, `create_alert_audit_queue`, `alert_email` | 100, 14, true, `""` | full profile: budget 350 |

Variable files: `terraform.tfvars` (auto-loaded, non-secret network values), `environments/full.tfvars`
(Jenkins, 2 nodes, min 0, max 3, t3.large, budget 350, **placeholder** admin CIDR `203.0.113.10/32` — a
documentation address), `environments/learning.tfvars` (no Jenkins, 1 node, 1-day backups, budget 100), and
the git-ignored `admin.auto.tfvars` (your real `/32`), passed **last** on the command line so it overrides the
placeholder.

## 6.2 Network

| Resource (block) | Why it exists | Security | Billing | During suspension | If deleted |
|---|---|---|---|---|---|
| `aws_vpc.main` | private network 10.0.0.0/16; DNS support + hostnames on (needed by EKS/RDS endpoints) | isolation boundary | free | kept | everything inside is lost |
| `aws_internet_gateway.igw` | internet access for public subnets | — | free | kept | ALB/Jenkins/NAT unreachable |
| `aws_subnet.public[0..1]` | ALB, NAT, Jenkins; tag `kubernetes.io/role/elb=1` lets the Load Balancer Controller auto-discover where to place internet-facing ALBs; `map_public_ip_on_launch = false` | nothing gets a public IP implicitly | free | kept | no ALB placement |
| `aws_subnet.private[0..1]` | EKS nodes/pods; tag `kubernetes.io/role/internal-elb=1` | no public IPs | free | kept | nodes cannot start |
| `aws_subnet.database[0..1]` | RDS only | own route table without internet routes | free | kept | RDS subnet group invalid |
| `aws_eip.nat` | static public IP of the NAT gateway (3.111.24.35) | — | public IPv4 ≈ $0.005/h | kept | NAT broken |
| `aws_nat_gateway.nat` | outbound internet for private subnets (pull images from ECR, reach AWS APIs, join the cluster); single NAT in public subnet 1, `depends_on` IGW | inbound connections impossible | ≈ $0.056/h + data | **kept** (see §6.9) | nodes cannot join/pull images |
| `aws_route_table.public` + 2 associations | `0.0.0.0/0 → IGW` | — | free | kept | public subnets offline |
| `aws_route_table.private` + 2 associations | `0.0.0.0/0 → NAT` | — | free | kept | nodes have no egress |
| `aws_route_table.database` + 2 associations | **no routes** (only the implicit local route) | DB tier isolated from the internet | free | kept | — |

## 6.3 Container registry

| Resource | Details |
|---|---|
| `aws_ecr_repository.backend`, `.frontend` | `order-inventory-backend/-frontend`; `image_tag_mutability = "IMMUTABLE"` (a pushed tag can never be overwritten), `scan_on_push = true`, `force_delete = true` (allows destroy with images — another reason never to destroy casually). Billing: storage only (~150 MB). Kept while suspended. |
| `aws_ecr_lifecycle_policy.app` (`for_each` backend/frontend) | expire images beyond the 20 most recent → bounded storage while keeping rollback history |

The unrelated repository `frontend` in the same account is **not** managed by Terraform and must be left alone.

## 6.4 EKS

| Resource | Why / key settings | Security | Billing | Suspension |
|---|---|---|---|---|
| `aws_security_group.eks_cluster` + egress rule | additional SG on the control-plane ENIs; Jenkins → API rule added in `jenkins.tf` | ingress only from Jenkins SG on 443 | free | kept |
| `aws_iam_role.eks_cluster` (trust `eks.amazonaws.com`) + `AmazonEKSClusterPolicy` | lets the EKS service manage ENIs etc. | AWS-managed policy | free | kept |
| `aws_eks_cluster.main` | name `order-inventory-eks`, version 1.36; `access_config` `API_AND_CONFIG_MAP` (access entries + legacy aws-auth) with `bootstrap_cluster_creator_admin_permissions = true` (the deployer user that created it is cluster admin); `vpc_config` in the **private** subnets, endpoint **private + public**, `public_access_cidrs = local.eks_public_access_cidrs`; `encryption_config` = envelope-encrypt Kubernetes `secrets` with `aws_kms_key.app`; `precondition`: allow-list must not be empty; `depends_on` the IAM attachments | public API only for the admin /32; nodes and Jenkins use the private endpoint | **≈ $0.10/h, always** (even with 0 nodes) | kept |
| `aws_iam_role.eks_nodes` (trust `ec2.amazonaws.com`) + `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` | what the nodes may do: join the cluster, manage pod IPs (VPC CNI), pull from ECR | managed policies | free | kept |
| `aws_eks_node_group.main` | `order-inventory-nodes`, private subnets, `t3.medium` ON_DEMAND, `scaling_config` desired/min/max from variables, `update_config.max_unavailable = 1`, **`lifecycle { ignore_changes = [scaling_config[0].desired_size] }`** | nodes in private subnets, EKS-managed cluster SG | 2 × t3.medium ≈ $65/month total when running | **desired 0** (definition kept) |
| `data.tls_certificate.eks` + `aws_iam_openid_connect_provider.eks` | registers the cluster's OIDC issuer in IAM → **IRSA** (pods assume IAM roles via service-account tokens) | thumbprint from the issuer certificate | free | kept |
| `aws_iam_role.ebs_csi` (+ policy doc with conditions `sub = system:serviceaccount:kube-system:ebs-csi-controller-sa`, `aud = sts.amazonaws.com`) + `AmazonEBSCSIDriverPolicy` | role for the EBS CSI driver add-on | only that service account can assume it | free | kept |
| `aws_iam_policy.lbc` (from `k8s/iam_policy.json`) + `aws_iam_role.lbc` (trust: only `kube-system:aws-load-balancer-controller`) + attachment | permissions for the AWS Load Balancer Controller to create ALBs/target groups/SGs | IRSA, single service account | free | kept |
| `aws_eks_addon.ebs_csi`, `.vpc_cni`, `.coredns`, `.kube_proxy` | managed add-ons; `resolve_conflicts_on_* = OVERWRITE`; `depends_on` the node group (their pods need nodes) | — | free | kept (pods return with nodes) |

**The node-group `ignore_changes`, explained.** The suspend script sets desired = 0 and the resume script sets it
back to 2 with the AWS API. Without `ignore_changes`, the next `terraform plan` would show
`desired_size: 0 → 2` (drift) and an `apply` would start nodes in the middle of a suspension. Ignoring only
`desired_size` hands that one attribute to the scripts while Terraform still manages instance type, subnets,
min and max. `node_min_size = 0` in `full.tfvars` was applied on 2026-10-19 (plan: exactly one in-place change
`min_size 1 → 0`), because AWS rejects desired < min. Resume uses min 1 while running.

## 6.5 Database (`main.tf`, explained in detail in [04-database.md](04-database.md))

| Resource | Key settings |
|---|---|
| `aws_security_group.rds` + `aws_vpc_security_group_ingress_rule.rds_mysql` | 3306 only from `aws_eks_cluster.main.vpc_config[0].cluster_security_group_id` (the EKS-created SG attached to every managed node) |
| `aws_subnet.database`, `aws_route_table.database`, associations | isolated DB tier |
| `random_password.db_master` | 32 characters with a restricted special-character set (MySQL-safe); generated once, stored in state |
| `aws_secretsmanager_secret.db_master` + `_version` | `order-inventory/rds-master`, JSON `{username,password,host,port,dbname}`, 7-day recovery window |
| `aws_db_subnet_group.mysql` | the two database subnets |
| `aws_db_parameter_group.mysql` | family `mysql8.4`: `require_secure_transport=1`, slow log, buffer pool 3/8 of RAM, `performance_schema=0` (pending-reboot); `create_before_destroy` so a replacement group exists before the old one is removed |
| `aws_db_instance.mysql` | `order-inventory-mysql`, MySQL 8.4, db.t3.micro, gp3 20→50 GB, encrypted, `publicly_accessible = false`, 7-day backups, windows, CloudWatch log exports, `skip_final_snapshot = true`, `deletion_protection = false`, `depends_on` the log groups |

Billing: instance hours (≈ $20.87/month estimate incl. storage when running), storage + backups beyond the
free allowance when stopped. Suspension: **stopped** (storage and backups kept). Deleting it: all data gone (no
final snapshot in this configuration). Secret: the password exists in the encrypted S3 state, Secrets Manager
and the KMS-encrypted Kubernetes Secret — never in Git or logs.

## 6.6 Jenkins (`jenkins.tf`)

| Resource | Key settings and reasons |
|---|---|
| `locals.jenkins_count` | 1 or 0 from `create_jenkins` (all Jenkins resources use `count`/`for_each`) |
| `aws_security_group.jenkins` | named `order-inventory-jenkins-sg` |
| `aws_vpc_security_group_ingress_rule.jenkins_ssh` / `jenkins_web` (`for_each = toset(var.admin_cidr_blocks)`) | 22 and 8080 **only** from each admin CIDR. `for_each` keyed by the CIDR string → when your IP changes, the old rule is destroyed and a new one created (this is what the resume script's targeted apply does) |
| `aws_vpc_security_group_egress_rule.jenkins_all_egress` | outbound anywhere (GitHub, ECR, package mirrors) — accepted risk AVD-AWS-0104 |
| `aws_vpc_security_group_ingress_rule.eks_api_from_jenkins` | 443 from the Jenkins SG to the EKS control-plane SG → Jenkins uses the **private** API endpoint |
| `aws_iam_role.jenkins` (trust `ec2.amazonaws.com`) | instance role → **no AWS keys stored in Jenkins** |
| `aws_iam_role_policy.jenkins_ecr_push` | `ecr:GetAuthorizationToken` (account-wide by design) + push/pull actions **only on the two app repositories** |
| `aws_iam_role_policy.jenkins_eks_access` | `eks:DescribeCluster` on this cluster only (needed by `aws eks update-kubeconfig`) |
| `aws_iam_role_policy.jenkins_ci_reports` | `s3:PutObject` into the CI-reports bucket only |
| `aws_iam_instance_profile.jenkins` | attaches the role to the instance |
| `data.aws_ami.ubuntu` | newest Canonical (`099720109477`) Ubuntu 24.04 amd64 gp3 AMI |
| `aws_instance.jenkins` | public subnet 1, key pair `UniversalKey`, the SG, the profile, `associate_public_ip_address = true`, **IMDSv2 required** (`http_tokens = "required"`, hop limit 2 so containers started by builds can still reach the metadata service), encrypted gp3 30 GB root volume, `lifecycle { ignore_changes = [ami, associate_public_ip_address] }` |
| `aws_eks_access_entry.jenkins` + `aws_eks_access_policy_association.jenkins` | the Jenkins role may use the cluster with `AmazonEKSEditPolicy` **scoped to the `order-inventory` namespace** (it cannot touch `kube-system`, other namespaces or cluster-scoped objects) |
| `random_password.ci_admin` (`jenkins-admin`, `sonarqube-admin`) + `aws_secretsmanager_secret.ci_admin` + `_version` | generated admin passwords (28 chars, mixed classes) in Secrets Manager `order-inventory/jenkins-admin` and `/sonarqube-admin`; read by `ansible/run-playbook.sh` |

### Why `ignore_changes = [ami, associate_public_ip_address]` was needed

- `ami`: `data.aws_ami.ubuntu` uses `most_recent = true`. When Canonical publishes a new image, the AMI id
  changes, and changing `ami` **forces replacement** of an instance. Without the ignore, a routine plan would
  propose destroying and recreating Jenkins (losing its disk).
- `associate_public_ip_address`: found during the suspension on 2026-10-19. A **stopped** instance has no public
  IP, and the AWS API then reports `associate_public_ip_address = false`. Terraform compared that with the
  configuration (`true`) and planned `false → true # forces replacement` — i.e. "destroy Jenkins and create a
  new one". Nothing was applied; the attribute was added to `ignore_changes`, after which the plan while
  suspended showed **no resource changes**, only the stale `jenkins_public_ip`/`jenkins_url` outputs.

**Limits and risks of `ignore_changes` (do not present it as a universal fix):** Terraform stops managing the
ignored attribute, so a deliberate change (e.g. you really want a new AMI or no public IP) is silently not
applied — you must use `terraform apply -replace=aws_instance.jenkins[0]` or remove the ignore temporarily.
It hides drift for that attribute. It is appropriate here because the attribute only matters at creation time
(AMI, public-IP association) or is intentionally controlled outside Terraform (node count).

## 6.7 Encryption, storage, monitoring

| File / resource | Purpose |
|---|---|
| `kms.tf` `aws_kms_key.app` (rotation on, 7-day deletion window) + `aws_kms_alias.app` (`alias/order-inventory-app`) | customer-managed key (≈ $1/month). Key policy: account root administers; **CloudWatch and Budgets** may `Decrypt`/`GenerateDataKey*` (needed to publish to an encrypted SNS topic — the AWS-managed `aws/sns` key does not allow that, so alarms would be silently undelivered); **SNS** may use it (deliver to the encrypted SQS queue) |
| `aws_iam_role_policy.eks_cluster_kms` | the EKS cluster role may Encrypt/Decrypt/CreateGrant on this key for Secret envelope encryption |
| `storage.tf` `aws_s3_bucket.ci_reports` (`bucket_prefix`) + public access block + `BucketOwnerEnforced` + SSE-S3 + versioning + lifecycle (expire 30 days, non-current 7 days, abort multipart 1 day) + TLS-only policy | Jenkins uploads per-build reports to `s3://<bucket>/<job>/<build>/`; `force_destroy = true` (reproducible content) |
| `monitoring.tf` | SNS topic (KMS), topic policy, SQS audit queue + policy + subscription, optional email subscription, 9 alarms, 2 RDS log groups (14 days), monthly budget — see [11-monitoring-logging.md](11-monitoring-logging.md) |

## 6.8 Outputs (`outputs.tf`)

22 outputs, e.g. `eks_cluster_name`, `rds_endpoint`, `jenkins_instance_id`, `jenkins_public_ip`, `jenkins_url`,
`aws_lbc_role_arn`, `db_secret_arn`, `alerts_sns_topic_arn`, `ci_reports_bucket`, `backend/frontend_ecr_repository_url`.
Scripts read them with `terraform output -raw <name>` instead of hard-coding IDs (`tfout` in the evaluation
library; `create-db-secret.sh`; `install-lb-controller.sh`; `create-alb-alarms.sh`; `run-playbook.sh`).
Outputs are values **from state**: `jenkins_public_ip` still shows the last IP Terraform saw. After Jenkins
restarts with a new IP, run `terraform apply -refresh-only -var-file=environments/full.tfvars
-var-file=admin.auto.tfvars` (updates state/outputs only, changes no resources) before `ansible/run-playbook.sh`.

## 6.9 Every AWS resource: suspension, restoration and cost

| Resource | Remains during suspension? | Restored by | Billed while suspended? |
|---|---|---|---|
| VPC, subnets, route tables, IGW, SGs, IAM roles/policies, OIDC provider, add-on definitions | yes | — | no |
| NAT gateway + EIP | yes | — | **yes** (≈ $0.056/h + ≈ $0.005/h) |
| EKS control plane | yes (ACTIVE) | — | **yes** (≈ $0.10/h) |
| Node group | definition yes, 0 instances | resume: `update-nodegroup-config` | no compute |
| RDS instance | stopped | resume: `start-db-instance` | storage/backups only |
| Jenkins EC2 | stopped, EBS kept | resume: `start-instances` | EBS only |
| ECR repos/images | yes | — | storage |
| Secrets Manager ×3, KMS key | yes | — | yes ($0.40/secret, $1/key per month) |
| S3 buckets (state, CI reports) | yes | — | negligible |
| CloudWatch alarms (9 Terraform) | yes (INSUFFICIENT_DATA) | — | $0.10/alarm/month |
| ALB + target groups + 4 ALB alarms (not Terraform-managed) | **deleted** | resume: Helm Ingress + `create-alb-alarms.sh` | no |

**Why the NAT gateway is not removed:** it would save ≈ $1.50/day, but worker nodes in private subnets need it
to bootstrap, register with the cluster and pull images from ECR (there are no VPC endpoints). Removing and
recreating it would require Terraform changes on every suspend/resume and add a failure point to the restore.
Kept deliberately (`docs/AWS_DEPLOYMENT.md`, "Cost while suspended"). The EKS control plane cannot be paused.

## 6.10 Plan, refresh, apply, state and drift

- **refresh**: Terraform reads the real attributes of every resource in state (part of every plan).
- **plan**: refresh + diff with the configuration; nothing changes. Exit code with `-detailed-exitcode`:
  0 = no changes, 2 = changes (including output-only changes), 1 = error.
- **apply**: executes a plan; `apply <saved-plan>` executes exactly that plan.
- **targeted plan** (`-target=…`): limits the plan to some resources and their dependencies; used by the
  resume script for the admin IP only (dry-run on 2026-10-25: *2 to add, 1 to change, 2 to destroy* — the two
  SG rules replaced and the cluster updated in place). Targeting is for exceptional, controlled cases.
- **drift**: real infrastructure differs from configuration/state. Checks performed: after apply (no changes),
  after the node-group change (no changes), while suspended (no resource changes after the Jenkins fix).
- **state is sensitive**: it contains every attribute, including `random_password` results. That is why the
  state is only in a private, encrypted, versioned, TLS-only bucket and `*.tfstate` is git-ignored. (Before the
  remediation, state files with a password had been committed to the public repository — see
  [10-security.md](10-security.md).)

## 6.11 Destruction and dependencies

Teardown order (`docs/RUNBOOKS.md` §8): delete the Ingress first (so the controller deletes the ALB, its
target groups and security groups, which Terraform does not know about and which would otherwise block VPC
deletion), uninstall the controller, delete the ALB alarms, then `terraform plan -destroy` → review →
`terraform destroy`. Secrets enter a 7-day recovery window and the KMS key a 7-day pending-deletion window.
For this project's evaluation period, **`terraform destroy` is forbidden**; suspension is used instead.

## 6.12 Viva questions

| Question | Answer |
|---|---|
| Difference between Terraform state and actual AWS state? | State = Terraform's stored record; AWS = reality. Plan refreshes state from AWS and shows differences (drift) against the configuration. |
| Why remote state with locking? | Shared, durable, encrypted state; locking prevents concurrent applies corrupting it. |
| Why was `ignore_changes` required for the Jenkins instance? | A stopped instance reports no public IP association and new AMIs change the AMI id; both force replacement. Ignoring these creation-time attributes prevents destroying Jenkins. |
| Why does the node-group desired size live outside Terraform? | Suspend/resume change it at runtime; Terraform must not revert it. |
| How does Terraform get the DB password without anyone typing it? | `random_password` → Secrets Manager → `create-db-secret.sh` → Kubernetes Secret. |
| Why three subnet tiers? | Public (ALB, NAT, Jenkins), private (nodes with NAT egress), database (no internet route at all). |
| What does IRSA give you? | Pods get short-lived AWS credentials for one IAM role bound to one service account, instead of using the node's role. |
| What happens to the ALB on `terraform destroy`? | Nothing — Terraform did not create it; it must be removed first by deleting the Ingress, otherwise VPC deletion fails. |
| Why is `terraform.tfvars` committed but `admin.auto.tfvars` not? | The first contains only non-sensitive defaults; the second contains your personal IP. |
