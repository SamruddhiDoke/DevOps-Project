# Part 16 — Architecture diagrams and request flows

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md)

Diagrams are Mermaid (editable text; rendered by GitHub and by VS Code Mermaid preview extensions). Every box
corresponds to a real resource or file in this repository.

## 1. High-level system architecture

```mermaid
flowchart LR
    dev["Developer laptop"] -->|git push| gh["GitHub repo"]
    jenkins["Jenkins on EC2"] -->|"polls every 5 min"| gh
    jenkins -->|"push images"| ecr[("Amazon ECR")]
    jenkins -->|"helm upgrade"| eks["EKS cluster"]
    user["Browser"] -->|"HTTP 80"| alb["Application Load Balancer"]
    alb --> eks
    eks -->|"pull images"| ecr
    eks -->|"MySQL 3306, TLS"| rds[("RDS MySQL")]
    eks -.->|"metrics"| cw["CloudWatch alarms"]
    rds -.->|"metrics"| cw
    cw --> sns["SNS topic"] --> sqs["SQS audit queue"]
    eks -.->|"container logs"| elk["ELK in the cluster"]
    tf["Terraform"] -.->|"creates"| aws["All AWS resources"]
    ans["Ansible"] -.->|"configures"| jenkins
```

Plain English: developers push to GitHub; Jenkins notices, tests and packages the app, stores images in ECR and
deploys them to EKS. Users reach the app through the ALB. The app stores data in RDS. CloudWatch watches the
infrastructure and notifies through SNS; ELK keeps searchable logs. Terraform built the AWS side; Ansible
configured Jenkins. Files: `Jenkinsfile`, `terraform/*.tf`, `ansible/`, `helm/order-inventory/`.

## 2. AWS VPC and network layout

```mermaid
flowchart TB
    internet(("Internet"))
    subgraph vpc["VPC 10.0.0.0/16 (ap-south-1)"]
      igw["Internet gateway"]
      subgraph pubA["Public 10.0.1.0/24 (1a)"]
        nat["NAT gateway + EIP"]
        jen["Jenkins EC2 (admin /32 only)"]
        albA["ALB node"]
      end
      subgraph pubB["Public 10.0.2.0/24 (1b)"]
        albB["ALB node"]
      end
      subgraph privA["Private 10.0.11.0/24 (1a)"]
        n1["EKS worker node"]
      end
      subgraph privB["Private 10.0.12.0/24 (1b)"]
        n2["EKS worker node"]
      end
      subgraph dbA["Database 10.0.21.0/24 (1a), no internet route"]
        rdsx[("RDS subnet")]
      end
      subgraph dbB["Database 10.0.22.0/24 (1b), no internet route"]
        rds[("RDS MySQL 10.0.22.34")]
      end
    end
    internet --- igw
    igw --- albA & albB & jen
    n1 & n2 -->|"0.0.0.0/0"| nat --> igw
    n1 & n2 -->|"3306 from cluster SG"| rds
```

Route tables (`terraform/main.tf`): public → IGW; private → NAT; database → local only. Security groups:
ALB SG (controller-managed, port 80), cluster SG (nodes/pods), RDS SG (3306 from cluster SG), Jenkins SG (22
and 8080 from the admin /32), control-plane SG (443 from Jenkins).

## 3. Application request flow (EKS)

```mermaid
sequenceDiagram
    participant B as Browser
    participant A as ALB (port 80)
    participant F as frontend pod (nginx)
    participant K as backend pod (Spring Boot)
    participant D as RDS MySQL
    B->>A: GET /orders
    A->>F: path "/" rule
    F-->>B: index.html (no-cache) + /assets/* (cached)
    B->>A: POST /api/orders (JSON)
    A->>K: path "/api" rule, target = pod IP
    K->>D: transaction: SELECT ... FOR UPDATE, UPDATE stock, INSERT order + items
    D-->>K: commit
    K-->>B: 201 Created + X-Request-Id
```

Files: `helm/order-inventory/templates/ingress.yaml`, `frontend/nginx/default.conf.template`,
`OrderController.java`, `OrderService.java`.

## 4. Database interaction (create order)

```mermaid
sequenceDiagram
    participant C as OrderController
    participant S as OrderService (@Transactional)
    participant U as UserRepository
    participant P as ProductRepository
    participant O as OrderRepository
    participant DB as MySQL
    C->>S: createOrder(@Valid OrderRequest)
    S->>U: findById(userId)
    U->>DB: SELECT users
    loop each distinct productId, ascending
        S->>P: findByIdForUpdate(id)
        P->>DB: SELECT ... FOR UPDATE (row lock)
    end
    S->>S: check stock, deduct, compute total (BigDecimal)
    S->>O: save(order with items, cascade)
    O->>DB: UPDATE products / INSERT orders, order_items
    S-->>C: OrderResponse
    Note over S,DB: COMMIT releases the locks, any exception causes ROLLBACK
```

## 5. GitHub-to-Jenkins CI/CD pipeline

```mermaid
flowchart LR
    push["git push main"] --> poll["SCM poll H/5"]
    poll --> co["Checkout, tag = build-commit"]
    co --> env["Environment check"]
    env --> bt["Backend tests + JaCoCo"]
    bt --> fb["Frontend lint, tests, build"]
    fb --> sq{"SonarQube quality gate"}
    sq -->|pass| tv{"Trivy deps, IaC, secrets"}
    tv -->|pass| hl["Helm lint + template"]
    hl --> db["Docker build x2"]
    db --> ti{"Trivy image gate"}
    ti -->|pass| id["AWS identity + cluster ACTIVE"]
    id --> ecr["Push to ECR"]
    ecr --> kc["kubeconfig + can-i"]
    kc --> dep{"deploy-k8s.sh: helm upgrade --wait"}
    dep -->|"pods Ready"| ver["Verify image tags"]
    dep -->|"not Ready"| rb1["helm rollback, exit 1"]
    ver --> hc{"Readiness + ALB smoke test"}
    hc -->|pass| ok["SUCCESS + summary"]
    hc -->|fail| rb2["post: rollback to previous revision"]
    sq -->|fail| stop["Build FAILED"]
    tv -->|fail| stop
    ti -->|fail| stop
```

## 6. Docker image build and ECR publishing

```mermaid
flowchart LR
    src["backend/ src + pom.xml"] --> b1["maven builder stage: mvn package"]
    b1 --> r1["temurin 17 JRE stage, user 10001"]
    fsrc["frontend/ src + package-lock"] --> b2["node 24 builder: npm ci, npm run build"]
    b2 --> r2["nginx-unprivileged stage, user 101"]
    r1 --> l1["order-inventory-backend:N-sha + OCI labels"]
    r2 --> l2["order-inventory-frontend:N-sha + OCI labels"]
    l1 & l2 --> scan{"Trivy image gate"}
    scan --> login["aws ecr get-login-password"]
    login --> push["docker push to IMMUTABLE repos"]
    push --> ecrscan["ECR scan on push"]
```

## 7. Helm deployment to EKS and ALB traffic

```mermaid
flowchart TB
    helm["helm upgrade order-inventory (image.tag=N-sha)"] --> api["EKS API server"]
    api --> depB["Deployment backend: maxSurge 1, maxUnavailable 0"]
    api --> depF["Deployment frontend"]
    api --> ing["Ingress order-inventory-ingress (class alb)"]
    depB --> rsNew["new ReplicaSet"] --> podNew["new pod: startup -> readiness OK"]
    depB --> rsOld["old ReplicaSet"] --> podOld["old pod: preStop 10s, graceful 20s"]
    lbc["AWS Load Balancer Controller (IRSA)"] -->|watches| ing
    lbc -->|"creates / updates"| alb["ALB k8s-orderinv-..."]
    alb --> tgB["target group backend (/api/health)"] --> podNew
    alb --> tgF["target group frontend (/healthz)"]
```

## 8. CloudWatch → SNS / SQS notification flow

```mermaid
flowchart LR
    rdsm["RDS metrics"] --> a1["5 RDS alarms"]
    ec2m["EC2 metrics"] --> a2["2 Jenkins alarms + node CPU alarm"]
    natm["NAT metrics"] --> a3["NAT port allocation alarm"]
    albm["ALB metrics"] --> a4["4 ALB alarms (script)"]
    budget["AWS Budget 80% actual / 100% forecast"] --> sns
    a1 & a2 & a3 & a4 --> sns["SNS order-inventory-alerts (KMS)"]
    sns --> sqs["SQS order-inventory-alerts-audit (KMS, 4 days)"]
    sns -.-> email["email (optional, not subscribed)"]
```

## 9. ELK logging flow

```mermaid
flowchart LR
    be["backend pods: ECS JSON with requestId"] --> files["/var/log/containers/*_order-inventory_*.log"]
    fe["frontend nginx: access log rid=..."] --> files
    files --> fb["Filebeat DaemonSet: container parser, k8s metadata, decode JSON"]
    fb --> es[("Elasticsearch, ILM delete 7d")]
    es --> kb["Kibana: data view filebeat-*, dashboard Order Inventory - Operations"]
    you["Operator"] -->|"kubectl port-forward 5601"| kb
```

## 10. Terraform provisioning flow

```mermaid
flowchart LR
    boot["terraform/bootstrap apply (once)"] --> bucket[("S3 state bucket, versioned, encrypted")]
    code["*.tf + full.tfvars + admin.auto.tfvars"] --> init["terraform init (S3 backend, lock file)"]
    bucket --> init
    init --> plan["terraform plan: refresh + diff"]
    plan --> review{"reviewed?"}
    review -->|yes| apply["terraform apply"]
    apply --> awsr["VPC, EKS, RDS, ECR, IAM, KMS, S3, SNS/SQS, alarms, budget, Jenkins EC2"]
    apply --> state["updated state in S3"]
```

## 11. Ansible configuration of Jenkins

```mermaid
flowchart LR
    sm[("Secrets Manager: jenkins-admin, sonarqube-admin")] --> rp["run-playbook.sh"]
    tfo["terraform output jenkins_public_ip"] --> rp
    rp -->|"extra vars JSON on stdin"| ctr["python:3.12-slim container with ansible-core 2.19"]
    ctr -->|SSH| host["Jenkins EC2"]
    host --> r1["common: packages, auto updates, SSH hardening"]
    r1 --> r2["docker"] --> r3["build_tools: JDK, Maven, Node, Trivy, Helm, kubectl, Terraform, AWS CLI"]
    r3 --> r4["jenkins: LTS repo, service"] --> r5["sonarqube: container on 127.0.0.1:9000, token"]
    r5 --> r6["jenkins_casc: plugins, casc.yaml, secrets env, job with pollSCM"]
```

## 12. Suspension and restoration sequence

```mermaid
sequenceDiagram
    participant Op as Operator
    participant S as suspend-evaluation.sh
    participant R as resume-evaluation.sh
    participant K as EKS / Helm
    participant A as AWS APIs
    Op->>S: run
    S->>A: preflight (identity, state, IDs)
    S->>S: write recovery manifest (tag, revision, sizes)
    S->>K: helm upgrade ingress.enabled=false
    K->>A: controller deletes ALB + target groups
    S->>K: scale apps and ES/Kibana to 0
    S->>A: node group desired 0 (wait ~17 min drain)
    S->>A: stop Jenkins EC2, stop RDS
    S->>A: verify images, secrets, state, PITR, no ALB
    Op->>R: run (later)
    R->>A: preflight, admin IP check (targeted TF if changed)
    R->>A: start RDS, start Jenkins, node group desired 2
    R->>K: wait nodes Ready + add-ons
    R->>A: wait RDS available
    R->>K: deploy-k8s.sh (Ingress enabled, tag from manifest)
    K->>A: controller creates NEW ALB
    R->>A: wait ALB active + targets healthy + /api/health
    R->>R: smoke test 20 checks, ALB alarms, ELK, Jenkins /login
    R-->>Op: URL + summary
```
