# Part 14 — CloudWatch, SNS, SQS, Budgets and ELK

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md)

Two complementary systems:

| | CloudWatch (+ SNS/SQS, Budgets) | ELK (Elasticsearch, Kibana, Filebeat) |
|---|---|---|
| Watches | **infrastructure metrics** emitted by AWS services (RDS CPU, memory, storage, connections; EC2 status/CPU; NAT errors; ALB 5xx/unhealthy hosts) and cost | **application and container logs** (every request, warning, error, with request id and Kubernetes metadata) |
| Question it answers | "Is something wrong and should someone be notified?" | "What exactly happened to this request / why did it fail?" |
| Where | AWS-managed | inside the EKS cluster (namespace `logging`) and optionally locally (Compose overlay) |
| Defined in | `terraform/monitoring.tf`, `scripts/create-alb-alarms.sh` | `k8s/logging/elk.yaml`, `order-inventory-platform/logging/*`, `docker-compose.logging.yml` |

## 11.1 CloudWatch alarms

*In general:* an alarm evaluates one metric statistic over a **period**; after **evaluation_periods**
consecutive breaching periods it goes `OK → ALARM`, and back when not breaching. `INSUFFICIENT_DATA` means no
data points (e.g. the resource is stopped). Actions (here: publish to SNS) run on state transitions.

Terraform alarms (`terraform/monitoring.tf`; all have `alarm_actions` = SNS topic; all except the NAT alarm
also notify on return to `OK`):

| Alarm name | Namespace / metric / dimension | Statistic, period × evaluations | Threshold | Why |
|---|---|---|---|---|
| `order-inventory-rds-cpu-high` | AWS/RDS `CPUUtilization`, DB id | Average, 300 s × 2 | > 80 % | sustained DB load |
| `order-inventory-rds-free-storage-low` | `FreeStorageSpace` | Minimum, 300 s × 1 | < 2 GiB | disk exhaustion (storage autoscaling to 50 GB exists) |
| `order-inventory-rds-freeable-memory-low` | `FreeableMemory` | Average, 300 s × 2 | < 25 MiB | **calibrated**: RDS's own OS leaves 40–60 MiB free on db.t3.micro even idle; 64 MiB fired permanently |
| `order-inventory-rds-swap-high` | `SwapUsage` | Average, 300 s × 3 | > 200 MiB | sustained memory pressure (the meaningful signal on small instances) |
| `order-inventory-rds-connections-high` | `DatabaseConnections` | Maximum, 300 s × 1 | > 50 | pool is 10 per pod; 50 means something is leaking/scaling unexpectedly |
| `order-inventory-jenkins-status-check-failed` | AWS/EC2 `StatusCheckFailed`, instance id | Maximum, 60 s × 3 | > 0 | instance or host problem |
| `order-inventory-jenkins-cpu-high` | `CPUUtilization` | Average, 300 s × 3 | > 85 % | overloaded CI host |
| `order-inventory-eks-nodes-cpu-high` | `CPUUtilization`, `AutoScalingGroupName` of the node group | Average, 300 s × 3 | > 80 % | nodes need scaling |
| `order-inventory-nat-port-allocation-errors` | AWS/NATGateway `ErrorPortAllocation` | Sum, 300 s × 1 | > 0 (`treat_missing_data = notBreaching`) | private egress failing |

ALB alarms (created by `scripts/create-alb-alarms.sh` because the ALB is not a Terraform resource; deleted by
suspend, recreated by resume): `order-inventory-alb-5xx` (`HTTPCode_ELB_5XX_Count` Sum 300 s > 10),
`order-inventory-alb-target-5xx` (`HTTPCode_Target_5XX_Count` Sum 300 s > 10), and one
`order-inventory-alb-unhealthy-hosts-<tg>` per target group (`UnHealthyHostCount` Maximum 60 s × 3 > 0 —
downtime detection). The script derives the CloudWatch dimension format `app/<name>/<id>` and
`targetgroup/<name>/<id>` from the ARNs.

**A real finding:** `rds-freeable-memory-low` fired on real metrics: swap was growing under MySQL 8.4 default
settings on the 1 GiB instance. The parameter group was tuned (buffer pool 3/8 of RAM, performance_schema off —
verified live), swap dropped to ~4 MB, and the threshold was recalibrated plus the swap alarm added
(`docs/TESTING.md`). This is monitoring working as intended.

Log groups: `/aws/rds/instance/order-inventory-mysql/error` and `/slowquery`, pre-created with 14-day retention
(otherwise RDS creates them with "never expire").

During suspension: the 9 Terraform alarms remain (`INSUFFICIENT_DATA` — verified 2026-10-25; NAT alarm `OK`
because missing data counts as not breaching); the 4 ALB alarms are deleted (their ALB no longer exists) and
recreated for the new ALB on resume.

## 11.2 SNS → SQS (and email) notification path

```text
CloudWatch alarm / AWS Budget ──publish──▶ SNS topic order-inventory-alerts (encrypted with KMS key alias/order-inventory-app)
                                              ├──▶ SQS queue order-inventory-alerts-audit (encrypted, 4-day retention)
                                              └──▶ email (only if TF_VAR_alert_email is set — currently NOT subscribed)
```

| Resource | Detail |
|---|---|
| `aws_sns_topic.alerts` | `kms_master_key_id = aws_kms_key.app.id` |
| `aws_sns_topic_policy.alerts` | account owner may manage; **service principals `cloudwatch.amazonaws.com` and `budgets.amazonaws.com` may publish** only for this account (`aws:SourceAccount` condition) |
| `aws_sqs_queue.alerts_audit` | `message_retention_seconds = 345600` (4 days), KMS-encrypted |
| `aws_sqs_queue_policy.alerts_audit` | only SNS may send, and only from this topic (`aws:SourceArn`) |
| `aws_sns_topic_subscription.alerts_audit` | protocol `sqs` |
| `aws_sns_topic_subscription.alerts_email` | created only when `alert_email` is non-empty |
| KMS key policy | CloudWatch/Budgets/SNS may use the key — without this, publishing to an encrypted topic fails silently |

**Verification (VERIFIED, `docs/TESTING.md`):** `aws cloudwatch set-alarm-state --alarm-name
order-inventory-rds-cpu-high --state-value ALARM --state-reason test` → a message arrived in the SQS queue with
the expected alarm name, new state and metric → alarm restored to `OK`. Reading the queue:
`aws sqs receive-message --queue-url $(terraform -chdir=terraform output -raw alerts_audit_queue_url)`.
Why an SQS "audit" queue: delivery can be proven and inspected from the CLI without a mailbox, and alerts
are kept for 4 days.

## 11.3 AWS Budgets

`aws_budgets_budget.monthly` (`order-inventory-monthly`): COST, MONTHLY, limit `monthly_budget_usd` (350 in the
full profile); notifications: **ACTUAL > 80 %** and **FORECASTED > 100 %** → SNS topic (and email if set).
Limitations: budget data is updated a few times per day (not real time), it alerts but **does not stop
spending**, actual spend is net of credits, and the notification path was never triggered because spend stayed
below the threshold (**IMPLEMENTED BUT NOT VERIFIED**). Observed 2026-10-25: actual $0.00, forecast $7.13 for
October as reported by AWS Budgets (indicative only).

## 11.4 ELK on EKS (`k8s/logging/elk.yaml`)

```text
backend pod stdout (ECS JSON) ─┐
frontend nginx access log ─────┼─▶ /var/log/containers/*_order-inventory_*.log on each node
                               │        ▼
                               │   Filebeat DaemonSet (one pod per node) ─▶ Elasticsearch (Deployment, 1 pod)
                               │                                              ▼
                               └──────────────────────────────────────────▶ Kibana (port-forward only)
```

There is **no Logstash** in this project: Filebeat does the light parsing itself (`decode_json_fields`) and
writes directly to Elasticsearch.

Block by block:

| Object | Key settings | Why |
|---|---|---|
| Namespace `logging` | | separation from the app |
| Deployment `elasticsearch` 8.19.5 | pod security: `runAsNonRoot`, UID/GID 1000, `fsGroup`, seccomp; **initContainer `copy-config`** copies the default config into an `emptyDir` (`cp -R`) because the root filesystem is read-only; env `discovery.type=single-node`, `xpack.security.enabled=false`, heap 512 MB, disk-watermark checks disabled (emptyDir on the node root volume), `ES_TMPDIR=/tmp`; readiness `/_cluster/health?local=true`; requests 200m/1Gi, limit 1 CPU/1Gi; read-only root fs, no capabilities; volumes `data`, `config`, `logs`, `tmp` = emptyDir | demo-sized single node; **data is lost when the pod or node goes away** (accepted: logs are diagnostic, 7-day retention) |
| Service `elasticsearch` :9200 | ClusterIP | only reachable inside the cluster |
| Deployment `kibana` 8.19.5 | `ELASTICSEARCH_HOSTS` = in-cluster FQDN, Node heap 512 MB, readiness `/api/status` (up to 30 failures), non-root, read-only root fs, emptyDir data/tmp | |
| Service `kibana` :5601 | ClusterIP | access only with `kubectl port-forward` — never published |
| ServiceAccount + ClusterRole + ClusterRoleBinding `filebeat` | get/list/watch namespaces, pods, nodes, replicasets | needed by `add_kubernetes_metadata` |
| ConfigMap `filebeat-config` | input `filestream` on `/var/log/containers/*_order-inventory_*.log` (**only the application namespace**) with the `container` parser; processors: `add_kubernetes_metadata` (pod, namespace, container, labels from the log path, global so every event gets it), `decode_json_fields` on lines starting with `{` (backend ECS JSON becomes fields such as `log.level`, `log.logger`, `requestId`, `service.environment`), `add_fields app=order-inventory`; output to Elasticsearch; ILM policy `order-inventory-logs` (rollover 1 day / 1 GB, **delete after 7 days**) | |
| DaemonSet `filebeat` | env `NODE_NAME` from the downward API; runs as **root** (UID 0) but read-only root fs, no privilege escalation, all capabilities dropped except `DAC_READ_SEARCH`; mounts `/var/log/containers` and `/var/log/pods` read-only; registry in hostPath `/var/lib/filebeat-data` | must read root-owned log files on the node — the one accepted Trivy exception (KSV-0118, path-scoped) |

Installed once by a cluster admin: `kubectl apply -f k8s/logging/elk.yaml`. Resources come from the existing
nodes (no extra AWS cost). Suspend scales Elasticsearch and Kibana to 0; resume scales them to 1, waits for
them and Filebeat, and checks Kibana `/api/status` through a temporary port-forward.

Kibana objects (`order-inventory-platform/logging/kibana-saved-objects.ndjson`, imported by `kibana-setup.sh`):
data view `filebeat-*` (`oi-logs`), four saved searches — "Backend warnings and errors", "Order failures
(rejected orders and status changes)", "Database availability problems", "Order lifecycle events" — and the
dashboard **Order Inventory - Operations** (`oi-operations`). Because they are stored in Elasticsearch (emptyDir), they must be **re-imported after every
resume** (see handbook §1.2.6).

### Local ELK (Compose)

`docker-compose.logging.yml` adds Elasticsearch/Kibana (ports bound to `127.0.0.1` only, security off — "do NOT
expose this configuration on a network"), Filebeat with Docker autodiscover for the three named containers
(`logging/filebeat.yml`, runs as root with the Docker socket mounted read-only), and switches the backend to
ECS JSON. Same ILM policy (`logging/ilm-policy.json`).

## 11.5 Tracing one request with its request id

1. The browser (or curl) receives an error, e.g. 400 for an order exceeding stock; the JSON contains
   `"requestId": "1ef5064e-…"` and the response header `X-Request-Id` has the same value.
2. Where the id comes from: nginx generates `$request_id` and forwards it as `X-Request-Id` (Compose path), or
   the backend's `RequestIdFilter` generates a UUID (ALB path, since the ALB sends `/api` directly to the
   backend). The filter puts it in the MDC → every backend log line of that request contains it.
3. Kibana → Discover → data view `filebeat-*` → query `requestId : "1ef5064e-…"`.
4. Result recorded on EKS (`docs/evidence/elk-eks-2026-10-19.txt`): 1 document — `WARN OrderService 'Order
   rejected for user 1: insufficient stock for product 1 (available 20, requested 999999)'` with
   `kubernetes.namespace=order-inventory`, the pod name, container `backend`, `service.environment=aws`.
5. Privacy check from the same evidence: the RDS password appeared in **0** indexed documents.

## 11.6 Commands

```bash
aws cloudwatch describe-alarms --alarm-name-prefix order-inventory --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
aws sqs receive-message --queue-url "$(terraform -chdir=terraform output -raw alerts_audit_queue_url)" --max-number-of-messages 5
kubectl -n logging get pods
kubectl -n logging port-forward svc/kibana 5601:5601            # then http://localhost:5601
bash order-inventory-platform/logging/kibana-setup.sh http://localhost:5601
kubectl -n order-inventory logs deploy/backend --tail=20       # raw ECS JSON lines
```

## 11.7 Viva questions

| Question | Answer |
|---|---|
| Difference between CloudWatch and ELK here? | CloudWatch = AWS metrics, alarms, notifications; ELK = searchable application/container logs for diagnosis. |
| How do you know alerts are delivered? | Forced an alarm state; the message arrived in the SQS audit queue subscribed to the SNS topic. |
| Why a customer-managed KMS key for SNS? | CloudWatch can only publish to an encrypted topic if the key policy allows it; the AWS-managed SNS key does not. |
| Why do alarms show INSUFFICIENT_DATA now? | The environment is suspended; stopped resources emit no metrics. |
| Is the budget a hard limit? | No, it only notifies (ACTUAL 80 %, FORECASTED 100 %); it never fired. |
| Why no Logstash? | Not needed: Filebeat parses JSON and adds Kubernetes metadata; fewer components to run. |
| What happens to logs during suspension? | Elasticsearch data is on emptyDir and is lost when the nodes are removed; logging restarts empty on resume. |
| How would you make logging production-grade? | Managed OpenSearch or CloudWatch Logs/Container Insights, persistent storage, security enabled, longer retention, alerting on log patterns. |
