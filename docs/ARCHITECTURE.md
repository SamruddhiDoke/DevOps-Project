# Architecture

Diagrams are Mermaid (rendered by GitHub; edit them as text).

## 1. Runtime on AWS

```mermaid
flowchart LR
    user[Browser] -->|HTTP :80| alb[Application Load Balancer<br/>created by AWS LB Controller]
    subgraph vpc[VPC 10.0.0.0/16 · ap-south-1a / ap-south-1b]
      subgraph pub[Public subnets]
        alb
        nat[NAT gateway]
        jenkins[Jenkins EC2<br/>admin CIDR only]
      end
      subgraph priv[Private subnets]
        subgraph eks[EKS 1.36 · managed node group]
          fe[frontend ×2<br/>nginx :8080]
          be[backend ×2<br/>Spring Boot :8080]
        end
        rds[(RDS MySQL 8.4<br/>encrypted · TLS-only)]
      end
    end
    alb -->|/api/*| be
    alb -->|/*| fe
    fe -. /api fallback proxy .-> be
    be -->|3306 from cluster SG only| rds
    eks -->|egress| nat
    jenkins -->|private API endpoint<br/>namespace-scoped| eks
    ecr[(ECR · immutable tags)] --> eks
    kms[KMS key] -. encrypts .-> eks
    rds -. metrics/logs .-> cw[CloudWatch alarms] --> sns[SNS topic<br/>KMS-encrypted] --> mail[Email]
    budget[AWS Budget] --> mail
    be -. ECS JSON logs .-> elk[Filebeat → Elasticsearch → Kibana]
```

Key decisions:
- **Same-origin API.** The browser always calls `/api`. The ALB routes `/api` to the backend; nginx in the
  frontend also proxies `/api`, so Docker Compose, port-forwarding and EKS use one frontend build.
- **Liveness vs readiness.** `/api/health` (no DB) drives liveness and ALB health; `/api/health/ready`
  (DB check) drives readiness. A database outage removes pods from traffic without restart loops.
- **Zero-downtime rollouts.** `maxUnavailable: 0`, readiness gating, 10 s `preStop` drain, graceful
  Spring shutdown, 20 s ALB deregistration delay, PDBs.
- **Schema ownership.** Flyway migrations own the schema; Hibernate validates it.

## 2. CI/CD

```mermaid
flowchart LR
    dev[git push] --> gh[GitHub]
    gh --> j[Jenkins]
    subgraph ci[Jenkinsfile]
      t1[Backend tests<br/>JUnit + JaCoCo] --> t2[Frontend lint/tests/build]
      t2 --> q[SonarQube<br/>quality gate]
      q --> s1[Trivy: deps, IaC,<br/>secrets]
      s1 --> h[Helm lint]
      h --> b[Docker build<br/>tag build-commit]
      b --> s2[Trivy image gate<br/>fixable HIGH/CRITICAL]
      s2 --> p[Push to ECR]
      p --> d[helm upgrade --wait]
      d -->|pods not Ready| rb1[helm rollback<br/>exit 1]
      d --> v[Verify image tags +<br/>in-cluster readiness +<br/>ALB smoke test]
      v -->|fails| rb2[post: rollback to<br/>previous revision]
    end
    j --> ci
    ci -. reports .-> s3[(S3 CI reports)]
```

## 3. Data model

```mermaid
erDiagram
    USERS ||--o{ ORDERS : places
    ORDERS ||--|{ ORDER_ITEMS : contains
    PRODUCTS ||--o{ ORDER_ITEMS : "ordered as"
    USERS { bigint id PK
            varchar name
            varchar email UK
            varchar phone
            datetime created_at }
    PRODUCTS { bigint id PK
               varchar name
               text description
               decimal price "CHECK > 0"
               int stock_quantity "CHECK >= 0"
               varchar category
               datetime created_at }
    ORDERS { bigint id PK
             bigint user_id FK
             decimal total_amount
             enum status
             datetime created_at }
    ORDER_ITEMS { bigint id PK
                  bigint order_id FK
                  bigint product_id FK
                  int quantity "CHECK > 0"
                  decimal price "unit price at order time" }
```

Order rules: creating an order locks the product rows (`SELECT … FOR UPDATE`, ascending id order) and
reserves stock atomically; cancelling restores stock exactly once; cancelled orders are final; products
referenced by orders cannot be deleted (409).

## 4. Environments

| Concern | Local (Compose) | Local Kubernetes (minikube) | AWS |
|---|---|---|---|
| Database | MySQL 8.4 container + named volume | MySQL fixture on a PVC | RDS MySQL 8.4 |
| Ingress | nginx on :3000 | `kubectl port-forward` | ALB |
| Images | built locally | `minikube image load` | ECR |
| Deploy | `docker compose up` | `scripts/deploy-k8s.sh local <tag> -f values-minikube.yaml` | Jenkins → `scripts/deploy-k8s.sh` |
| Logs | ELK overlay | `kubectl logs` (ECS JSON) | ECS JSON on stdout; ship with Filebeat |
| Alerts | — | — | CloudWatch → SNS, AWS Budget |
