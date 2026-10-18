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

## 2. Provision AWS (requires cost approval — see README "Cost")

```powershell
cd terraform
$env:TF_VAR_db_password = Read-Host -AsSecureString "RDS password" | ConvertFrom-SecureString -AsPlainText
$env:TF_VAR_alert_email = "you@example.com"          # budget + alarm emails (confirm the SNS email)
# edit environments/full.tfvars (or learning.tfvars): set admin_cidr_blocks to your IP/32
terraform init
terraform plan -var-file=environments/full.tfvars -out tfplan
terraform apply tfplan                                 # ~20 min
```

Cluster bootstrap (once, as the cluster creator; *bash*):

```bash
aws eks update-kubeconfig --region ap-south-1 --name order-inventory-eks
kubectl apply -f k8s/namespace.yaml
./scripts/create-db-secret.sh          # reads TF_VAR_db_password + rds_endpoint
./scripts/install-lb-controller.sh     # AWS Load Balancer Controller (IRSA)
```

Configure Jenkins on EC2 (*bash*, from `ansible/`):

```bash
cp inventory.example.ini inventory.ini   # set ansible_host = terraform output jenkins_public_ip
ansible-playbook playbooks/jenkins.yml --check   # dry run
ansible-playbook playbooks/jenkins.yml
```

Then open `terraform output jenkins_url`, unlock with the password from
`sudo cat /var/lib/jenkins/secrets/initialAdminPassword`, install suggested plugins + `coverage`,
create a Pipeline job from SCM (`Jenkinsfile`), and set global env vars `CI_REPORTS_BUCKET`
(`terraform output ci_reports_bucket`) and, if you run SonarQube, `SONAR_HOST_URL` + a
`sonarqube-token` secret-text credential.

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
kubectl -n order-inventory delete ingress order-inventory-ingress
# wait until no k8s-orderinv load balancers remain:
aws elbv2 describe-load-balancers --region ap-south-1 --query "LoadBalancers[?contains(LoadBalancerName,'k8s-orderinv')].LoadBalancerName"
helm uninstall aws-load-balancer-controller -n kube-system
aws cloudwatch describe-alarms --region ap-south-1 --alarm-name-prefix order-inventory-alb --query "MetricAlarms[].AlarmName" --output text | xargs -r aws cloudwatch delete-alarms --region ap-south-1 --alarm-names
cd terraform && terraform plan -destroy -var-file=environments/full.tfvars   # review
terraform destroy -var-file=environments/full.tfvars
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
(http://localhost:18090) with generated credentials in `ci/.env`. On the EC2 Jenkins, the Code Quality
stage runs only when `SONAR_HOST_URL` is set (SonarQube is not provisioned in AWS to avoid an always-on
instance); otherwise the stage is reported as skipped in the build log.
