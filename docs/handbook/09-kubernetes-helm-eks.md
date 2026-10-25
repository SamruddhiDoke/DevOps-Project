# Part 12 — AWS EKS, Kubernetes, Helm and the ALB

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md)

## 9.1 EKS: control plane vs worker nodes

| Part | Who runs it | In this project | Billed |
|---|---|---|---|
| **Control plane** (API server, etcd, scheduler, controller manager) | AWS, in AWS-managed accounts, highly available | cluster `order-inventory-eks`, Kubernetes 1.36; API endpoint public (admin /32 only) + private (VPC) | per cluster-hour (≈ $0.10/h) **whether or not any nodes exist** |
| **Worker nodes** | EC2 instances in your account | managed node group `order-inventory-nodes`, 2 × t3.medium, private subnets, Amazon Linux 2023 | per instance-hour while running |
| **Add-ons** | EKS-managed | `vpc-cni` (gives every pod a real VPC IP), `coredns` (cluster DNS), `kube-proxy` (Service routing), `aws-ebs-csi-driver` | run as pods on the nodes |
| **AWS Load Balancer Controller** | Helm chart 3.6.0 in `kube-system`, IRSA role `order-inventory-aws-lbc-role` (`scripts/install-lb-controller.sh`) | turns Ingress objects into ALBs | the ALB it creates is billed |

That is why a suspended cluster (0 nodes) still costs ≈ $73/month: the control plane keeps running and keeps
the cluster's state (Deployments, Services, Secrets, Helm history), which is what allows a 10-minute restore.

**API access:** `kubectl` from the laptop goes to the public endpoint, allowed only from
`public_access_cidrs` (the admin /32); nodes and Jenkins use the private endpoint inside the VPC (Jenkins via
the SG rule on 443). Authentication: the deployer IAM user is cluster admin (creator); the Jenkins role has an
**access entry** with edit rights in namespace `order-inventory` only.

## 9.2 Kubernetes objects in the application namespace

```text
Namespace order-inventory
├── Deployment backend   → ReplicaSet backend-<hash> (one per pod-template version) → Pod ×2
├── Deployment frontend  → ReplicaSet frontend-<hash>                                  → Pod ×2
├── Service backend  (ClusterIP :8080)      Service frontend (ClusterIP :80 → 8080)
├── ConfigMap backend-config                Secret mysql-secret (url, username, password)
├── PodDisruptionBudget backend, frontend   Ingress order-inventory-ingress (class alb)
└── Helm release secrets sh.helm.release.v1.order-inventory.v<N>  (release history)
```

- **Deployment**: desired state (image, replicas, probes, update strategy). It manages **ReplicaSets**.
- **ReplicaSet**: keeps N identical pods of one pod-template version running. A rolling update creates a new
  ReplicaSet and scales it up while scaling the old one down; old ReplicaSets are kept (`revisionHistoryLimit:
  10`) for `kubectl rollout undo` (this project uses Helm rollback instead).
- **Pod**: one running instance (here one container per pod) with its own VPC IP.
- **Service**: stable name and virtual IP in front of the pods matching its selector; only **Ready** pods are
  in its endpoints. `backend.order-inventory.svc.cluster.local` resolves through CoreDNS.
- **What happens when a pod crashes**: the container restarts in place (restartPolicy Always, with
  back-off); if the pod or node disappears, the ReplicaSet creates a replacement on any node with capacity.
  While not Ready it receives no traffic. Verified "pod loss → replacement Ready" on minikube.

## 9.3 The Helm chart (`helm/order-inventory/`)

Helm renders templates with values into Kubernetes manifests and installs them as a **release** with
numbered **revisions** stored in the cluster. `helm history` lists them; `helm rollback <release> <rev>`
re-applies an earlier revision as a new revision.

### `Chart.yaml`
`apiVersion: v2`, `name: order-inventory`, `type: application`, chart `version: 1.0.0`, `appVersion: "1.0.0"`
(the real version is the image tag, also shown in the `app.kubernetes.io/version` label).

### `values.yaml` (every key)

| Key | Value | Used by |
|---|---|---|
| `image.registry` / `image.tag` | `""` / `""` (set per release by `deploy-k8s.sh`) | `oi.image` helper |
| `image.pullPolicy` | `IfNotPresent` (immutable tags make this safe) | both Deployments |
| `environment` | `aws` | ConfigMap `APP_ENVIRONMENT` |
| `config.corsAllowedOrigins`, `config.logFormat: ecs`, `config.javaOpts` | ConfigMap | backend env |
| `database.existingSecret` | `mysql-secret` | backend `secretKeyRef` |
| `backend.replicas` / `frontend.replicas` | 2 / 2 | Deployments |
| `backend.resources` | requests 250m CPU / 512Mi, limits 500m / 1Gi | scheduling and limits |
| `frontend.resources` | requests 100m / 128Mi, limits 250m / 256Mi | |
| `rollingUpdate.maxUnavailable` / `maxSurge` | **0 / 1** | both Deployments |
| `preStopSleepSeconds` | 10 | preStop hook and grace periods |
| `podDisruptionBudget.enabled` / `minAvailable` | true / 1 | `pdb.yaml` |
| `ingress.enabled`, `className: alb`, annotations | see §9.5 | `ingress.yaml` |

`values-minikube.yaml` overrides: `image.registry: local`, `environment: minikube`, `ingress.enabled: false`,
smaller resources.

### `templates/_helpers.tpl`

```gotemplate
{{- define "oi.labels" -}} app.kubernetes.io/part-of: order-inventory; app.kubernetes.io/managed-by: {{ .Release.Service }};
app.kubernetes.io/version: {{ .Values.image.tag | quote }}; helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }} {{- end }}
{{- define "oi.image" -}}
{{- $tag := required "image.tag is required (immutable build tag, never latest)" $root.Values.image.tag -}}
{{- if eq $tag "latest" -}}{{- fail "image.tag must be an immutable build tag, not latest" -}}{{- end -}}
{{ printf "%s/%s:%s" registry repo tag }} (or "repo:tag" without a registry)
{{- define "oi.podSecurityContext" -}} runAsNonRoot: true; seccompProfile: { type: RuntimeDefault } {{- end }}
```
`required` and `fail` make rendering **fail** without a tag or with `latest` (verified: "Chart refuses missing
or `latest` tag"). The pod security context refuses to start containers running as root and applies the
runtime's default seccomp syscall filter.

### `templates/backend.yaml` (Deployment + Service)

| Lines | Setting | Meaning |
|---|---|---|
| 9–15 | `replicas`, `revisionHistoryLimit: 10`, `strategy: RollingUpdate` with `maxUnavailable: 0`, `maxSurge: 1` | during an update never fewer than 2 Ready pods; at most 3 pods exist |
| 16–22 | selector/labels `app: backend` | Service and PDB select these pods |
| 23–25 | annotation `checksum/config: <sha256 of configmap.yaml>` | a change in the ConfigMap changes the pod template → automatic rolling restart (ConfigMap changes otherwise do not restart pods) |
| 27 | `terminationGracePeriodSeconds: preStop + 35` = 45 s | enough for 10 s preStop + 20 s graceful shutdown + margin |
| 28–29 | pod security context | non-root, seccomp |
| 32–33 | `image` via `oi.image`, `imagePullPolicy` | e.g. `…/order-inventory-backend:8-18a2bc6` |
| 34–36 | port `http` 8080 | named port used by probes and the Service |
| 37–39 | `envFrom: configMapRef backend-config` | non-secret env |
| 40–55 | `SPRING_DATASOURCE_URL/USERNAME/PASSWORD` from `secretKeyRef` `mysql-secret` | credentials never in the chart |
| 58–63 | `startupProbe` `/api/health`, every 5 s, 36 failures allowed (= up to 180 s to start) | liveness checks begin only after start-up succeeded → slow JVM starts are not killed |
| 64–70 | `livenessProbe` `/api/health`, 10 s, timeout 3 s, 3 failures | restarts a hung JVM; no DB dependency |
| 71–77 | `readinessProbe` `/api/health/ready`, 5 s, timeout 3 s, 3 failures | traffic only when the DB is reachable |
| 78–81 | `preStop: sleep 10` | keeps serving while the endpoint and ALB deregistration propagate |
| 82–86 | container security context: no privilege escalation, **read-only root filesystem**, drop ALL capabilities | |
| 87–94 | `/tmp` as `emptyDir` | the JVM/Tomcat need a writable temp dir |
| 90–91 | resources from values | |
| 96–113 | Service `backend` ClusterIP 8080 → `http`; annotation `alb.ingress.kubernetes.io/healthcheck-path: /api/health` | the ALB target group health check uses liveness |

### `templates/frontend.yaml`

Same strategy; grace period preStop + 20 = 30 s; env `BACKEND_URL =
http://backend.<namespace>.svc.cluster.local:8080` (fully-qualified because nginx's resolver ignores DNS
search domains); readiness and liveness on `/healthz`; no privilege escalation, capabilities dropped (no
read-only root filesystem: the nginx entrypoint writes the rendered config at start); Service `frontend` port
80 → 8080 with ALB health-check path `/healthz`.

### `templates/configmap.yaml`, `pdb.yaml`, `ingress.yaml`, `NOTES.txt`

- ConfigMap `backend-config`: `APP_ENVIRONMENT`, `CORS_ALLOWED_ORIGINS`, `JAVA_OPTS`,
  `LOGGING_STRUCTURED_FORMAT_CONSOLE` (only if `logFormat` set).
- PDB per app with `minAvailable: 1`: a **voluntary** disruption (node drain, cluster upgrade) may not evict a
  pod if that would leave fewer than 1 available. (Scaling a Deployment to 0 is not an eviction, so the
  suspend script scales the apps to 0 first.)
- Ingress (only if `ingress.enabled`): class `alb`; rules `/api` (Prefix) → `backend:8080`, `/` (Prefix) →
  `frontend:80`. The longer prefix wins, so `/api/orders` goes to the backend and everything else to nginx.
- NOTES: printed after install (tag, revision, how to get the ALB hostname, rollback command).

## 9.4 Zero-downtime rolling update — how the pieces fit

1. `helm upgrade` changes the image tag → the Deployment creates a new ReplicaSet.
2. `maxSurge: 1`, `maxUnavailable: 0` → one **new** pod is added; no old pod is removed yet.
3. New pod: startup probe → readiness `/api/health/ready` passes → added to the Service endpoints and
   registered as an ALB target (target type `ip`); the ALB then health-checks it (`/api/health`, every 15 s,
   2 successes = healthy). Note: no ALB **pod readiness gate** is configured (that would require the namespace
   label `elbv2.k8s.aws/pod-readiness-gate-inject`), so Kubernetes does not wait for the ALB's own health check
   before continuing; the ALB keeps routing to the remaining healthy old target meanwhile, and the 10 s preStop
   plus 20 s deregistration delay cover the hand-over. The measured result was 0 failed requests; adding the
   readiness gate would make this guarantee explicit.
4. Only now one **old** pod is terminated: it is removed from endpoints and ALB deregistration starts
   (`deregistration_delay` 20 s); meanwhile its `preStop` sleeps 10 s so requests still in flight or routed
   during propagation are served; then SIGTERM → Spring graceful shutdown finishes in-flight requests (≤ 20 s).
5. Repeat until all pods are new. `helm --wait` returns success when all new pods are Ready.
6. If new pods never become Ready (bad image, wrong DB secret), the old pods were never removed; after the
   timeout `deploy-k8s.sh` rolls back.

Evidence (AWS, through the public ALB, `docs/evidence/aws-zero-downtime-2026-10-19.txt`): rolling releases
1,712 and 1,702 requests, non-existent image 1,982, never-Ready release 2,394, restart 1,742 → **9,532
requests, 0 non-200**; both bad releases → deploy exit 1 and automatic rollback.

## 9.5 Ingress → ALB (AWS Load Balancer Controller)

Annotations from `values.yaml`:

| Annotation | Effect |
|---|---|
| `alb.ingress.kubernetes.io/scheme: internet-facing` | ALB in the public subnets (found via the `kubernetes.io/role/elb` tag) |
| `target-type: ip` | targets are **pod IPs** directly (possible because of the VPC CNI), not node ports |
| `listen-ports: '[{"HTTP":80}]'` | HTTP listener on 80 (no HTTPS: no certificate) |
| `healthcheck-interval-seconds: "15"`, `healthy-threshold-count: "2"` | faster detection of new healthy targets |
| `target-group-attributes: deregistration_delay.timeout_seconds=20` | drain time for removed targets (default would be 300 s) |
| Service annotation `healthcheck-path` | `/api/health` (backend), `/healthz` (frontend) |

How it works: the controller (pods in `kube-system`) watches Ingress objects with class `alb`, calls the
ELBv2/EC2 APIs with its IRSA role and creates an ALB named `k8s-orderinv-orderinv-<hash>`, a security group,
listener rules for the paths and one target group per Service (`k8s-orderinv-backend-…`,
`k8s-orderinv-frontend-…`), then keeps target registrations in sync with the Ready pods. When the Ingress is
deleted, the controller deletes all of it (an Ingress finalizer makes Kubernetes wait for that). The ALB is
therefore **not** a Terraform resource, and its DNS name is assigned by AWS at creation time.

**Why the ALB is removed during suspension and how the URL is found again:** an ALB costs money per hour and
needs nodes behind it anyway. Suspend sets `ingress.enabled=false` via Helm → the controller deletes the ALB
(this must happen while the controller still has nodes to run on). Resume deploys the chart with defaults
(`ingress.enabled: true`) → a **new** ALB with a **new** DNS name; the script reads it from
`kubectl get ingress … -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`, waits for the ALB to be
active, the targets healthy and DNS to resolve, and prints it.

## 9.6 Scaling: replicas vs nodes

| | Scaling application replicas to 0 | Scaling the node group to 0 |
|---|---|---|
| Command | `kubectl -n order-inventory scale deploy backend frontend --replicas=0` | `aws eks update-nodegroup-config --scaling-config minSize=0,maxSize=3,desiredSize=0` |
| Effect | pods deleted; Deployments, Services, Secrets, Helm release remain | EC2 worker instances drained and terminated; **all** pods (including system pods) disappear |
| Cost effect | none by itself (nodes still run) | node compute cost → 0; control plane still billed |
| Restore | `kubectl scale … --replicas=2` or `helm upgrade` | `update-nodegroup-config desiredSize=2` → new instances join (~1 min measured) |
| Why both in suspend | apps first (fast, clean, avoids PDB-blocked evictions) then nodes | |

There is no Horizontal Pod Autoscaler or Cluster Autoscaler in this project (fixed sizes).

## 9.7 Bootstrap scripts

- `scripts/install-lb-controller.sh`: reads cluster name, IRSA role ARN and VPC id from Terraform outputs;
  `helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --version 3.6.0` in
  `kube-system` with `serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<role>` (IRSA); waits for the rollout.
- `scripts/create-db-secret.sh`: reads `order-inventory/rds-master` from Secrets Manager (ARN from
  `terraform output db_secret_arn`), extracts fields with Node, builds the JDBC URL with `sslMode=REQUIRED`
  and applies Secret `mysql-secret` with `kubectl create … --dry-run=client -o yaml | kubectl apply -f -`
  (create-or-update, idempotent); `unset` the variables; prints only the host. Alternative mode with explicit
  `DB_HOST/DB_USER/DB_PASSWORD` for minikube.
- `k8s/namespace.yaml`: the namespace object.

## 9.8 Database outage behaviour on Kubernetes

Two time scales:

- **Short outage (seconds):** readiness needs 3 failures × 5 s ≈ 15 s before a pod is marked unready, so pods
  stay in service; requests that need the database get a fast **503 from the application**
  ("database temporarily unavailable") instead of hanging. This is what the AWS RDS reboot showed: 3 × 503 on
  `/api/products` within ~1 s, liveness 88/88 OK, 0 restarts.
- **Longer outage:** readiness fails → Kubernetes removes the pods from the Service endpoints → the Load
  Balancer Controller (which registers only Ready endpoints as targets) deregisters them from the backend
  target group; with no healthy target the ALB itself answers 503 for `/api`. The frontend (static UI) keeps
  working. Liveness keeps passing → **no restarts**. When the DB returns, readiness passes and the pods are
  re-registered automatically. Minikube test: all backend pods unready, 0 restarts, automatic recovery.

## 9.9 Inspection commands

```bash
export AWS_PROFILE=order-inventory AWS_REGION=ap-south-1
aws eks update-kubeconfig --name order-inventory-eks --alias order-inventory-eks
kubectl get nodes -o wide
kubectl -n order-inventory get deploy,rs,pods,svc,ingress,pdb -o wide
kubectl -n order-inventory describe pod <pod>              # events: scheduling, pulls, probe failures
kubectl -n order-inventory get events --sort-by=.lastTimestamp | tail -20
kubectl -n order-inventory logs deploy/backend --tail=50
kubectl -n order-inventory rollout status deploy/backend
kubectl -n order-inventory rollout history deploy/backend
helm -n order-inventory list
helm -n order-inventory history order-inventory --max 10
helm -n order-inventory get values order-inventory          # user-supplied values of the current revision
kubectl -n kube-system get deploy aws-load-balancer-controller coredns
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50
```

## 9.10 Viva questions

| Question | Answer |
|---|---|
| Why EKS instead of ECS? | Kubernetes skills and tooling are portable (Helm, kubectl, same chart on minikube and EKS — verified locally first); rich health/rollout primitives; ecosystem (Load Balancer Controller, Filebeat DaemonSet). ECS would be simpler and has no control-plane fee; it was a learning/portability trade-off. |
| Deployment vs ReplicaSet? | A ReplicaSet keeps N copies of one pod template; a Deployment manages ReplicaSets to roll between versions and roll back. |
| Readiness vs liveness? | Readiness = may this pod receive traffic now (DB reachable)? Liveness = is the process healthy or must it be restarted? Startup = has it finished starting (delays liveness). |
| What happens when all worker nodes are scaled to zero? | All pods are gone (they cannot run anywhere); the control plane keeps the objects; the Ingress-less app is offline; restoring nodes reschedules the pods automatically (Deployments still want 2 replicas unless scaled down). |
| Why does EKS still cost money with no nodes? | The managed control plane runs 24/7 and is billed per cluster-hour. |
| How does the ALB get created from an Ingress? | The AWS Load Balancer Controller watches Ingresses of class `alb` and creates/updates the ALB, listeners, rules and target groups through the AWS API using its IRSA role. |
| Why target-type ip? | The ALB sends traffic straight to pod IPs; health checks reflect individual pods; no extra kube-proxy hop. |
| Why `maxUnavailable: 0`? | Capacity never drops below the desired replica count during an update; new pods must be Ready before old ones go. |
| Why a preStop sleep? | Endpoint removal and ALB deregistration are asynchronous; sleeping keeps the pod serving until no new requests are routed to it. |
| What does a PDB protect against? | Voluntary evictions (drains, upgrades) taking down all replicas at once. |
| How is configuration separated from secrets? | ConfigMap for non-secret settings; Secret (KMS-encrypted in etcd) for credentials, injected as env vars. |
