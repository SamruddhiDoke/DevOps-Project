# Runbooks

Commands are for **PowerShell** unless marked *bash* (run bash scripts from Git Bash or WSL).

---

## 1. Local start / stop (Docker Compose)

```powershell
cd order-inventory-platform
Copy-Item .env.example .env          # first time; edit passwords/ports
docker compose up -d --build
docker compose ps                    # mysql, backend, frontend: healthy
Start-Process http://localhost:3000
docker compose stop                  # stop; keeps containers and data
docker compose down                  # remove containers; KEEPS the data volume
```

Never run `docker compose down -v` unless you intend to delete the database.

Verification (*bash*): `./scripts/smoke-test.sh http://localhost:3000` (20 checks) and
`COMPOSE_PROJECT_NAME=oi-check ./scripts/compose-acceptance-test.sh` (8 checks, isolated volume).

## 2. Provision AWS (exactly as done on 2026-10-18 — see docs/AWS_DEPLOYMENT.md)

Use a scoped IAM identity, not root (the deployer user/policy is in `aws/iam/`):

```bash
export AWS_PROFILE=order-inventory AWS_REGION=ap-south-1
# 1. Remote state bucket (once)
terraform -chdir=terraform/bootstrap init && terraform -chdir=terraform/bootstrap apply
# 2. Your admin IP (git-ignored file; re-check if your ISP changes it)
printf 'admin_cidr_blocks = ["%s/32"]\n' "$(curl -s https://checkip.amazonaws.com)" > terraform/admin.auto.tfvars
# 3. Infrastructure (~20 min). Pass admin.auto.tfvars LAST so it overrides the profile placeholder.
cd terraform && terraform init
terraform plan -var-file=environments/full.tfvars -var-file=admin.auto.tfvars -out deploy.tfplan   # review
terraform apply deploy.tfplan
```

No password is typed: Terraform generates the RDS, Jenkins and SonarQube admin passwords into Secrets
Manager (`order-inventory/rds-master`, `/jenkins-admin`, `/sonarqube-admin`). Optional email alerts:
`TF_VAR_alert_email=you@example.com` (confirm the SNS email). Every alert is also copied to the SQS
queue `order-inventory-alerts-audit`.

Cluster bootstrap (once, as the cluster creator):

```bash
aws eks update-kubeconfig --name order-inventory-eks --alias order-inventory-eks
kubectl apply -f k8s/namespace.yaml
./scripts/create-db-secret.sh          # reads Secrets Manager; prints only the host
./scripts/install-lb-controller.sh     # AWS Load Balancer Controller v3.6.0 (IRSA)
kubectl apply -f k8s/logging/elk.yaml  # optional: in-cluster ELK
```

Configure Jenkins + SonarQube on EC2 (no local Ansible needed; runs in a container, secrets streamed
from Secrets Manager, never printed):

```bash
SSH_KEY=~/Downloads/UniversalKey.pem ./ansible/run-playbook.sh --check   # dry run
SSH_KEY=~/Downloads/UniversalKey.pem ./ansible/run-playbook.sh           # idempotent (re-run: changed=0)
git remote add jenkins-mirror ubuntu@$(terraform -chdir=terraform output -raw jenkins_public_ip):/srv/git/devops-project.git
GIT_SSH_COMMAND="ssh -i ~/Downloads/UniversalKey.pem -o IdentitiesOnly=yes" git push jenkins-mirror main
```

Jenkins (`terraform output jenkins_url`, reachable only from your IP) comes up fully configured as code:
admin user (password in `order-inventory/jenkins-admin`), job `order-inventory` polling the mirror,
SonarQube token credential, `SONAR_HOST_URL`, `CI_REPORTS_BUCKET`. SonarQube listens on 127.0.0.1:9000
only — open it with `ssh -L 9000:127.0.0.1:9000 ubuntu@<jenkins-ip>`.

## 3. Deploy

Normally Jenkins does this on every push to `main`. Manually (*bash*):

```bash
REGISTRY=$(terraform -chdir=terraform output -raw aws_account_id).dkr.ecr.ap-south-1.amazonaws.com
TAG=manual-$(git rev-parse --short HEAD)
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin $REGISTRY
for s in backend frontend; do
  docker build -t $REGISTRY/order-inventory-$s:$TAG order-inventory-platform/$s
  docker push $REGISTRY/order-inventory-$s:$TAG
done
./scripts/deploy-k8s.sh $REGISTRY $TAG        # waits for Ready; rolls back automatically on failure
ALB=$(kubectl -n order-inventory get ingress order-inventory-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
SMOKE_READ_ONLY=1 ./scripts/smoke-test.sh http://$ALB
./scripts/create-alb-alarms.sh                # once, after the first ALB exists
```

## 4. Rollback

| Situation | What happens / what to do |
|---|---|
| New pods never become Ready (crash, bad image, DB unreachable) | Automatic: `deploy-k8s.sh` runs `helm rollback` to the last good revision, exits 1, pipeline fails |
| Release Ready but post-deploy health check fails | Automatic: Jenkins `post { failure }` rolls back to the recorded previous revision |
| Problem discovered later | `helm -n order-inventory history order-inventory` then `helm -n order-inventory rollback order-inventory <REVISION> --wait` |
| Redeploy a known-good build | `./scripts/deploy-k8s.sh <registry> <older-tag>` (ECR keeps the last 20 immutable tags) |

Database migrations are forward-only; a rollback runs the previous application version against the
newer schema, so migrations must stay backward compatible for one release (add columns/tables; drop
them in a later release).

## 5. Recovery

- **Backend pods 0/1 Ready, no restarts:** database unreachable (by design). Check RDS status, the
  `mysql-secret` values, and that the RDS SG allows the EKS cluster SG. Pods return automatically.
- **Pod crash loop:** `kubectl -n order-inventory logs deploy/backend --previous`; a Flyway failure is
  logged as `FlywayMigrateException` — fix the migration, then `flyway repair` (see section 7).
- **RDS data loss:** restore point-in-time (`aws rds restore-db-instance-to-point-in-time`, retention
  7 days by default), point `mysql-secret` at the new endpoint, `kubectl rollout restart deployment/backend`.
- **Local data loss:** restore a dump: `Get-Content backup.sql | docker exec -i inventory-mysql mysql -uroot -p`.
- **Jenkins host lost:** `terraform apply` recreates it; re-run the Ansible playbook; the job definition is the Jenkinsfile.

## 6. Trace a failed order (logs)

1. The UI shows the API error; the response body contains `requestId` (also the `X-Request-Id` header).
2. Kibana (local ELK overlay, http://localhost:5601 → Discover, data view `filebeat-*`):
   `requestId : "<id>"` shows every backend log line of that request; nginx access lines contain `rid=<id>`.
3. Business events to look for: `Order rejected for user <id>: insufficient stock for product <id>`,
   `Order <id> created for user <id>`, `Order <id> status change rejected`, `Database unavailable`.
4. On EKS without ELK: `kubectl -n order-inventory logs deploy/backend --since=1h | Select-String <id>`.

## 7. Database operations

```powershell
# Flyway status / repair (local Compose network; use the RDS endpoint + TLS on AWS)
docker run --rm --network order-inventory-platform_inventory-network flyway/flyway:12-alpine `
  "-url=jdbc:mysql://mysql:3306/order_inventory_db?allowPublicKeyRetrieval=true&useSSL=false" `
  -user=root "-password=$env:MYSQL_ROOT_PASSWORD" info
# Backup before risky changes
docker exec inventory-mysql sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --databases order_inventory_db' > backup.sql
```

## 8. Teardown (order matters) and verification

The ALB and its target groups/security groups are created by the Load Balancer Controller, not
Terraform. Destroying the VPC first fails with dependency errors (this happened before).

```bash
export AWS_PROFILE=order-inventory AWS_REGION=ap-south-1
kubectl delete -f k8s/logging/elk.yaml --ignore-not-found
kubectl -n order-inventory delete ingress order-inventory-ingress
# wait until no k8s-orderinv load balancers remain:
aws elbv2 describe-load-balancers --region ap-south-1 --query "LoadBalancers[?contains(LoadBalancerName,'k8s-orderinv')].LoadBalancerName"
helm uninstall aws-load-balancer-controller -n kube-system
aws cloudwatch describe-alarms --region ap-south-1 --alarm-name-prefix order-inventory-alb --query "MetricAlarms[].AlarmName" --output text | xargs -r aws cloudwatch delete-alarms --region ap-south-1 --alarm-names
cd terraform && terraform plan -destroy -var-file=environments/full.tfvars -var-file=admin.auto.tfvars   # review
terraform destroy -var-file=environments/full.tfvars -var-file=admin.auto.tfvars
# Secrets Manager secrets: 7-day recovery window; KMS key: 7-day pending deletion.
# The state bucket (terraform/bootstrap) is kept; destroy it separately once the state is no longer needed.
```

Post-teardown checklist (all must be empty):

```bash
R=ap-south-1
aws eks list-clusters --region $R
aws rds describe-db-instances --region $R --query 'DBInstances[].DBInstanceIdentifier'
aws ec2 describe-nat-gateways --region $R --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId'
aws ec2 describe-addresses --region $R --query 'Addresses[].PublicIp'
aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].LoadBalancerName'
aws elbv2 describe-target-groups --region $R --query "TargetGroups[?contains(TargetGroupName,'k8s-orderinv')].TargetGroupName"
aws ec2 describe-instances --region $R --filters Name=tag:Project,Values=order-inventory Name=instance-state-name,Values=running,stopped
aws ec2 describe-volumes --region $R --filters Name=tag:Project,Values=order-inventory
aws ecr describe-repositories --region $R --query "repositories[?starts_with(repositoryName,'order-inventory')]"
aws kms list-aliases --region $R --query "Aliases[?AliasName=='alias/order-inventory-app']"   # key enters 7-day pending deletion
```

## 9. SonarQube

Local: `./ci/start-local-ci.sh` starts SonarQube (http://localhost:19000) and Jenkins
(http://localhost:18090) with generated credentials in `ci/.env`. On AWS, SonarQube 26.10 runs as a
container on the Jenkins EC2 host (Ansible role `sonarqube`, bound to 127.0.0.1:9000, data in Docker
volumes) and the pipeline enforces its quality gate. Admin password: Secrets Manager
`order-inventory/sonarqube-admin`; UI via `ssh -L 9000:127.0.0.1:9000 ubuntu@<jenkins-ip>`. If
`SONAR_HOST_URL` is unset, the stage reports itself as skipped.
