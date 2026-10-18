# Operational checklist

## Before every release (Jenkins enforces these)
- [ ] Backend tests green (`mvn verify`), zero-test runs fail the build
- [ ] Frontend lint, tests and build green
- [ ] SonarQube quality gate passed
- [ ] Trivy: no fixable HIGH/CRITICAL image vulnerabilities, no CRITICAL dependency vulnerabilities, no new IaC findings, no secrets
- [ ] Image tagged `<build>-<commit>` (never `latest`)
- [ ] Schema changes are new Flyway migrations, backward compatible for one release

## Deploy
- [ ] `helm upgrade --wait` succeeded (otherwise rolled back automatically)
- [ ] Both deployments run the new tag (Kubernetes Verification stage)
- [ ] `/api/health/ready` = UP in-cluster; ALB read-only smoke test passed
- [ ] Watch: `kubectl -n order-inventory get pods`, Kibana *Order Inventory – Operations*, CloudWatch alarms

## Before provisioning AWS
- [ ] Not using root access keys (`aws sts get-caller-identity` shows the deployer user)
- [ ] `TF_VAR_db_password` set (new, never the old exposed password); `admin_cidr_blocks` = your IP/32
- [ ] `TF_VAR_alert_email` set and SNS subscription confirmed (budget + alarms)
- [ ] `terraform plan` reviewed: only expected creations, no replacements/destroys
- [ ] Remote state configured (`backend.tf.example`) if anyone else will run Terraform

## After provisioning
- [ ] Cluster bootstrap: namespace, `create-db-secret.sh`, `install-lb-controller.sh`
- [ ] Ansible playbook applied to Jenkins; Jenkins unlocked; job created; `CI_REPORTS_BUCKET` set
- [ ] First deployment green; `create-alb-alarms.sh` run
- [ ] Test an alarm: `aws cloudwatch set-alarm-state --alarm-name order-inventory-rds-cpu-high --state-value ALARM --state-reason test`

## Teardown (same day for demos)
- [ ] Delete Ingress → ALB gone → uninstall LB controller → delete ALB alarms
- [ ] `terraform plan -destroy` reviewed → `terraform destroy`
- [ ] Post-teardown checklist in docs/RUNBOOKS.md §8 shows nothing billable

## Periodic
- [ ] Monthly: rebuild images (`--pull`) to pick up base-image fixes; review Trivy/Sonar results
- [ ] Check EKS/RDS versions are in standard support (`aws eks describe-cluster-versions`)
- [ ] Review AWS Budget and Cost Explorer; rotate the deployer access key every 90 days
- [ ] Keep `ci/jenkins/Dockerfile` and `ansible/group_vars/all.yml` tool versions in sync
