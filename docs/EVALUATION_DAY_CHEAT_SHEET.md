# Evaluation-day cheat sheet

One page. Full explanations: [COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md](COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md) §1.

## 0. Where am I?

```powershell
cd "C:\Users\Siddesh\Desktop\DevOps Project"     # every command below runs from here
```

| Fact | Value |
|---|---|
| AWS account / region / CLI profile | `038215676861` / `ap-south-1` / `order-inventory` |
| Identity the scripts expect | `arn:aws:iam::038215676861:user/order-inventory-deployer` (never root) |
| EKS cluster / node group | `order-inventory-eks` / `order-inventory-nodes` (2 × t3.medium when running) |
| RDS / Jenkins EC2 | `order-inventory-mysql` / `i-03288b455e674765e` |
| Release restored by resume | `lastKnownGoodTag` in [`recovery/evaluation-manifest.json`](recovery/evaluation-manifest.json) (`8-18a2bc6` at the last suspend) |
| GitHub | `https://github.com/SamruddhiDoke/DevOps-Project` (branch `main`) |

## 1. Restore (start **≥ 45 min** before the evaluation)

```powershell
aws sts get-caller-identity --profile order-inventory          # must show order-inventory-deployer
powershell -ExecutionPolicy Bypass -File scripts\resume-evaluation.ps1
```
Git Bash alternative: `bash scripts/resume-evaluation.sh`

Expected: about 9–10 minutes (measured 9 min 14 s), **plus a few minutes if your home IP changed**
(the script then updates the allowed /32 with a targeted Terraform change). Success looks like:

```text
ENVIRONMENT RESTORED AND VERIFIED in <m>m <s>s
   Application : http://k8s-orderinv-orderinv-....ap-south-1.elb.amazonaws.com
   Jenkins     : http://<new-ip>:8080
```
The ALB hostname and the Jenkins IP are **new every time**. Copy them from this output.

## 2. After restore: three things to know

1. **Jenkins will build the newest GitHub commit by itself** (SCM polling every 5 minutes) about
   5–15 minutes after restore, and deploy it as a zero-downtime rolling update. Let it finish before the
   evaluation (or show it live as the CI/CD demo).
2. **Kibana starts empty** (Elasticsearch stores data in the pod only). Re-import the dashboard:
   ```bash
   kubectl -n logging port-forward svc/kibana 5601:5601        # leave running (terminal 2)
   bash order-inventory-platform/logging/kibana-setup.sh http://localhost:5601
   ```
3. Jenkins password (copies to the clipboard; do not show it on the projector):
   ```powershell
   aws secretsmanager get-secret-value --secret-id order-inventory/jenkins-admin --query SecretString --output text --profile order-inventory --region ap-south-1 | Set-Clipboard
   ```

## 3. Five-minute health check

```bash
export AWS_PROFILE=order-inventory AWS_REGION=ap-south-1
kubectl get nodes                                         # 2 × Ready
kubectl -n order-inventory get pods,svc,ingress           # backend 2/2, frontend 2/2, ingress has ADDRESS
helm -n order-inventory history order-inventory --max 3   # last = deployed
URL=http://$(kubectl -n order-inventory get ingress order-inventory-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s $URL/api/health/ready                             # {"status":"UP","database":"UP"}
SMOKE_READ_ONLY=1 bash scripts/smoke-test.sh $URL         # "All 8 read-only checks passed"
```

## 4. Demo order (8 minutes)

1. Architecture diagram (handbook §16 / `docs/ARCHITECTURE.md`).
2. Browser → ALB URL → Dashboard → Products → **Orders → Create Order** → stock drops → **Cancel** → stock returns.
3. Jenkins → job `order-inventory` → **Build with Parameters** (DEPLOY ✔) → show stages while it runs.
4. `aws ecr describe-images --repository-name order-inventory-backend --query 'imageDetails[].imageTags[]' --output text`
5. `kubectl -n order-inventory get deploy,rs,pods,svc,ingress`; `helm -n order-inventory history order-inventory`.
6. Evidence of zero downtime: `docs/evidence/aws-zero-downtime-2026-10-19.txt` (9,532 requests, 0 errors).
7. Kibana → Discover → search a `requestId` from a failed order (handbook §14).
8. Cost: suspend/resume scripts and what stays billable (below).

Fallback if AWS/internet fails: local stack
`cd order-inventory-platform; docker compose up -d --build` → http://localhost:3000, plus the evidence files.

## 5. Suspend after the evaluation

```powershell
powershell -ExecutionPolicy Bypass -File scripts\suspend-evaluation.ps1 --plan   # read-only preview
powershell -ExecutionPolicy Bypass -File scripts\suspend-evaluation.ps1          # ~23 min (17 min = EKS draining nodes)
```
Ends with `SUSPENDED. Restore with: bash scripts/resume-evaluation.sh`. Never use `terraform destroy`
for this: RDS is configured with `skip_final_snapshot = true`, so destroy would delete the database
without a final snapshot.

Still billed while suspended: EKS control plane, NAT gateway + its public IP, EBS (Jenkins disk),
RDS storage/backups, Secrets Manager, KMS, CloudWatch alarms, ECR/S3 storage.
**RDS restarts itself 7 days after a stop** (date in the manifest, `rdsAutoRestartAfter`). Re-run
the suspend script after that date; it then only stops RDS.

## 6. If something fails

| Symptom | Do this |
|---|---|
| `FAILED in stage: ...` | Read `reason:`; fix it; **run the same command again** (scripts are idempotent) |
| `wrong AWS account` / `profile ... not usable` | `aws configure --profile order-inventory`; check `aws sts get-caller-identity --profile order-inventory` |
| `cannot reach the Kubernetes API` | Your IP changed. Run the **resume** script; it updates the allowed IP |
| Stuck on `RDS available` | `aws rds describe-events --source-identifier order-inventory-mysql --source-type db-instance --duration 60` |
| Stuck on `node(s) Ready` | `kubectl get nodes`; `kubectl get events -A --sort-by=.lastTimestamp \| tail -20` |
| Helm deploy failed | Already rolled back. `kubectl -n order-inventory logs deploy/backend --tail=50`; re-run resume |
| ALB URL does not open yet | New ALB DNS can take a few minutes; the script waits up to 10 min |
