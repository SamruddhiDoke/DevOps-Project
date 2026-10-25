# Part 3 — Repository and file-by-file inventory

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md)

The repository has **180 tracked files** (`git ls-files`, commit `b5f0454`, before this handbook was added).
This chapter shows the real tree, then explains every project-owned file in tables. The last column of each
table says which chapter explains the file further and at what depth:

- **L** = line by line / small block by block in that chapter
- **B** = by logical blocks (file is long but repetitive, e.g. UI markup)
- **C** = by category only (generated, third-party or data/evidence files, explained in §3.12)

## 3.1 Directory tree (tracked files)

```text
DevOps Project/
├── .gitattributes  .gitignore  .gitleaksignore  .trivyignore.yaml
├── CONTRIBUTING.md  README.md  Jenkinsfile
├── order-inventory-platform/                 ← the application
│   ├── .env.example  README.md
│   ├── docker-compose.yml                    ← local MySQL + backend + frontend
│   ├── docker-compose.logging.yml            ← optional local ELK overlay
│   ├── database/README.md
│   ├── logging/  filebeat.yml  ilm-policy.json  kibana-saved-objects.ndjson  kibana-setup.sh
│   ├── backend/                              ← Spring Boot REST API (Java 17)
│   │   ├── pom.xml  Dockerfile  .dockerignore
│   │   └── src/
│   │       ├── main/java/com/example/orderinventory/
│   │       │   ├── OrderInventoryApplication.java
│   │       │   ├── config/      CorsConfig  RequestIdFilter
│   │       │   ├── controller/  HealthController  OrderController  ProductController  UserController
│   │       │   ├── dto/         HealthResponse  OrderItemRequest  OrderItemResponse  OrderRequest
│   │       │   │                OrderResponse  OrderStatusUpdateRequest  ProductRequest  ProductResponse
│   │       │   │                UserRequest  UserResponse
│   │       │   ├── entity/      Order  OrderItem  OrderStatus  Product  User
│   │       │   ├── exception/   BadRequestException  ErrorResponse  GlobalExceptionHandler
│   │       │   │                ResourceNotFoundException
│   │       │   ├── repository/  OrderItemRepository  OrderRepository  ProductRepository  UserRepository
│   │       │   └── service/     OrderService  ProductService  UserService
│   │       ├── main/resources/  application.properties
│   │       │   └── db/ migration/V1__initial_schema.sql  V2__indexes_and_integrity_checks.sql
│   │       │       seed/R__demo_data.sql
│   │       └── test/  java/.../ ApiIntegrationTest  FailurePathWebTest  OrderConcurrencyTest
│   │                            RequestCorrelationTest  dto/ProductResponseTest
│   │                  resources/application-test.properties
│   └── frontend/                             ← React + Vite SPA served by nginx
│       ├── package.json  package-lock.json  vite.config.js  eslint.config.js  index.html
│       ├── Dockerfile  .dockerignore  sonar-project.properties
│       ├── nginx/  default.conf.template  security-headers.conf
│       └── src/  main.jsx  App.jsx  App.test.jsx  index.css
│           ├── components/  ConfirmDialog Header Icons Modal Sidebar StatCard StatusBadge Toast (.jsx)
│           ├── pages/       Dashboard Login Orders Products Users (.jsx)  workflows.test.jsx
│           ├── hooks/       useToasts.js  useToasts.test.js
│           ├── services/    api.js  api.test.js
│           └── test/        setup.js  helpers.js
├── helm/order-inventory/                     ← Helm chart deployed to EKS / minikube
│   ├── Chart.yaml  values.yaml  values-minikube.yaml
│   └── templates/  _helpers.tpl backend.yaml frontend.yaml configmap.yaml ingress.yaml pdb.yaml NOTES.txt
├── k8s/  namespace.yaml  iam_policy.json  logging/elk.yaml  testing/mysql-test-fixture.yaml
├── terraform/                                ← AWS infrastructure
│   ├── backend.tf main.tf jenkins.tf kms.tf storage.tf monitoring.tf variables.tf outputs.tf
│   ├── terraform.tfvars  environments/full.tfvars  environments/learning.tfvars
│   ├── .terraform.lock.hcl
│   └── bootstrap/  main.tf  .terraform.lock.hcl     ← creates the S3 state bucket
├── ansible/                                  ← configures the Jenkins EC2 host
│   ├── ansible.cfg  requirements.yml  inventory.example.ini  run-playbook.sh
│   ├── group_vars/all.yml  playbooks/jenkins.yml  test/test-in-container.sh
│   └── roles/ common docker build_tools jenkins git_mirror sonarqube jenkins_casc
├── ci/                                       ← local Jenkins + SonarQube (Docker)
│   ├── docker-compose.ci.yml  start-local-ci.sh
│   └── jenkins/  Dockerfile  casc.yaml  plugins.txt
├── scripts/                                  ← deploy, test and operations scripts
│   ├── deploy-k8s.sh smoke-test.sh create-db-secret.sh install-lb-controller.sh create-alb-alarms.sh
│   ├── aws-zero-downtime-test.sh k8s-acceptance-test.sh compose-acceptance-test.sh
│   ├── suspend-evaluation.sh resume-evaluation.sh (+ .ps1 wrappers)
│   └── lib/evaluation-common.sh
├── aws/iam/order-inventory-deployer-iam.json
└── docs/  API ARCHITECTURE AWS_DEPLOYMENT OPERATIONS_CHECKLIST RUNBOOKS SECURITY TESTING (.md)
    ├── evidence/  (9 recorded outputs)   recovery/evaluation-manifest.json
    ├── COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md  EVALUATION_DAY_CHEAT_SHEET.md  handbook/ (this chapter set)
```

## 3.2 Files that are intentionally **not** in Git (from `.gitignore`)

| Pattern | What it is | Why excluded |
|---|---|---|
| `**/node_modules/`, `**/frontend/dist/`, `**/frontend/coverage/`, `**/backend/target/`, `*.class` | dependencies and build output | reproducible from `package-lock.json` / `pom.xml`; large; history was cleaned of them |
| `**/.terraform/`, `*.tfstate*`, `*.tfplan`, `tfplan` | provider binaries, state, saved plans | state and plans can contain secrets (e.g. the generated RDS password); state lives in S3 |
| `*.tfvars` (except `terraform/terraform.tfvars`, `terraform/environments/*.tfvars`, `*.tfvars.example`) | local variable files, e.g. `terraform/admin.auto.tfvars` (your IP) | personal/sensitive values |
| `.env`, `.env.*` (except `.env.example`), `ci/.env` | local passwords | secrets |
| `*.pem`, `*.key`, `*.crt`, `*.p12`, `*.jks` | keys/certificates | secrets |
| `ansible/inventory.ini` | real Jenkins host address and key path | environment-specific |
| `.deploy/` | `previous-revision`, evaluation logs, zero-downtime test output | run-time state |
| `reports/` | CI reports | build output (archived by Jenkins and in S3) |
| `.idea/`, `.vscode/`, `*.iml`, `.DS_Store`, `Thumbs.db`, `*.log`, `*.tmp` | editor/OS/log files | noise |

## 3.3 Root files

| File | Purpose and important contents | Used by / when | Depends on | Design rationale | If wrong or missing | Likely viva question | Chapter |
|---|---|---|---|---|---|---|---|
| `Jenkinsfile` | Declarative pipeline: 15 stages from Checkout to Deployment Summary, params `DEPLOY`, `FULL_SMOKE_TEST`, `post` rollback | Jenkins job `order-inventory` on every build | `scripts/deploy-k8s.sh`, `scripts/smoke-test.sh`, Helm chart, tools on the agent, instance role | pipeline as code, versioned with the app | no CI/CD; a syntax error fails every build | "Walk me through your pipeline." | 08 (L) |
| `README.md` | project overview, status banner, quick start, cost table, limitations | humans, GitHub front page | — | single entry point | onboarding harder | — | — |
| `CONTRIBUTING.md` | branch/commit workflow, local quality gates, rules (no secrets, Flyway only, immutable images, pinned tools) | contributors | — | codifies conventions | conventions drift | "How would a new developer contribute?" | 01 |
| `.gitattributes` | `* text=auto eol=lf`; `*.ps1 eol=crlf`; images binary | Git on checkout/commit | — | shell scripts must have LF to run in Linux containers; PowerShell prefers CRLF | `bash\r: command not found` errors on Linux agents | "Why does a Windows repo force LF?" | 01 |
| `.gitignore` | ignore rules (§3.2) | Git | — | keep secrets and build output out of history | secrets/state could be committed (this happened before the remediation) | "How do you keep state files out of Git?" | 01 |
| `.gitleaksignore` | two reviewed false-positive fingerprints (SonarQube factory-default `admin:admin` in an old version of `ci/start-local-ci.sh`) | gitleaks scans | the commit `939b41a…` | documented exceptions instead of disabling the scanner | the scan reports the same false positive forever | "Is ignoring a finding safe?" | 10 |
| `.trivyignore.yaml` | 5 accepted Trivy misconfiguration IDs with statements (AVD-AWS-0040/0041/0104/0132, KSV-0118 path-scoped to `k8s/logging/elk.yaml`) | `trivy config --ignorefile .trivyignore.yaml` in the Jenkinsfile | — | every exception is justified and narrow | build fails on accepted findings, or (if too broad) hides real ones | "Why did you ignore some Trivy findings?" | 10 (L) |

## 3.4 Application — backend (`order-inventory-platform/backend`)

| File | Purpose and important contents | Used by / when | Depends on | Design rationale | If wrong or missing | Likely viva question | Chapter |
|---|---|---|---|---|---|---|---|
| `pom.xml` | Spring Boot 4.1.1 parent, Java 17, starters (webmvc, data-jpa, validation, flyway), `flyway-mysql`, `mysql-connector-j` (runtime), H2 + test starters (test), JaCoCo, security overrides `tomcat.version` 11.0.25 and `jackson-bom.version` 3.1.7, Sonar properties | Maven in Docker build stage and Jenkins "Backend Tests" | Maven Central | dependency versions managed by the Boot parent; overrides fix Trivy findings | no build; missing JaCoCo → no coverage in Sonar | "What does the parent POM give you?" | 03 (L) |
| `Dockerfile` | 2 stages: `maven:3.9-eclipse-temurin-17-alpine` builds `app.jar` (tests skipped: CI runs them); `eclipse-temurin:17-jre-alpine` runtime, `apk upgrade`, user 10001, `JAVA_OPTS` heap 75 % of limit, `HEALTHCHECK`, `exec java` | `docker compose build`, Jenkins "Docker Build" | `pom.xml`, `src/` | small runtime image without Maven/JDK; non-root numeric UID for `runAsNonRoot` | image fails to build or runs as root | "Why multi-stage?" | 05 (L) |
| `.dockerignore` | excludes `.git`, `target/`, IDE files, logs, `.env*`, keys | Docker build context | — | smaller context, no secrets in images | slower builds; risk of copying secrets | "What is the build context?" | 05 (L) |
| `src/main/java/.../OrderInventoryApplication.java` | `@SpringBootApplication` + `main` | JVM start | Spring Boot | standard entry point | app does not start | "What does @SpringBootApplication do?" | 03 (L) |
| `config/CorsConfig.java` | `WebMvcConfigurer` allowing configured origins on `/api/**` | every cross-origin request | `app.cors.allowed-origins` (env `CORS_ALLOWED_ORIGINS`) | same-origin in practice; configurable if UI moves | cross-origin UI would be blocked | "Why is CORS needed at all?" | 03 (L) |
| `config/RequestIdFilter.java` | reuses/creates `X-Request-Id`, validates it (`[A-Za-z0-9._:-]{1,128}`), puts it in MDC, echoes it in the response | first filter of every request (`HIGHEST_PRECEDENCE`) | SLF4J MDC | log correlation; prevents log injection | no request tracing in logs | "How do you trace one request?" | 03 (L) |
| `controller/HealthController.java` | `GET /api/health` (liveness, no DB), `GET /api/health/ready` (DB `isValid(2)`; 503 when down) | probes, ALB health checks, smoke tests, UI badge | `DataSource` | liveness must not restart pods during DB outages | restart loops or traffic to broken pods | "Readiness vs liveness?" | 03 (L) |
| `controller/OrderController.java` | `GET /api/orders`, `GET /{id}`, `POST` (201), `PUT /{id}/status` | HTTP | `OrderService` | thin controller; logic in service | order API missing | "Why PUT for status?" | 03 (L) |
| `controller/ProductController.java` | `GET`, `GET /{id}`, `POST` (201), `PUT /{id}`, `DELETE /{id}` (204) | HTTP | `ProductService` | REST resource conventions | product API missing | "Why 204 for delete?" | 03 (L) |
| `controller/UserController.java` | `GET`, `GET /{id}`, `POST` (201) | HTTP | `UserService` | — | user API missing | — | 03 (L) |
| `dto/*Request.java` (5 files) | request bodies with Bean Validation (`@NotNull`, `@NotBlank`, `@Size`, `@Min`, `@DecimalMin`, `@Email`, element-level `@Valid`) | `@Valid @RequestBody` in controllers | Jakarta Validation | validate at the edge, never expose entities | invalid data reaches services/DB | "Why DTOs instead of entities?" | 03 (L) |
| `dto/*Response.java` (5 files) | response shapes; `ProductResponse.calculateStatus` (≤0 OUT, ≤10 LOW, else IN); `HealthResponse` omits null fields | serialised to JSON by Jackson | — | stable API contract, computed fields | API contract changes accidentally | "Where is stock status computed?" | 03 (L) |
| `entity/User.java`, `Product.java`, `Order.java`, `OrderItem.java`, `OrderStatus.java` | JPA mappings to `users`, `products`, `orders`, `order_items`; `@PrePersist` timestamps; `Order` ↔ `OrderItem` one-to-many cascade; enum stored as string | Hibernate | Flyway schema (validated) | schema owned by Flyway; Hibernate only validates | app refuses to start (`ddl-auto=validate`) | "What is @ManyToOne fetch EAGER/LAZY?" | 03 (L) |
| `exception/BadRequestException.java`, `ResourceNotFoundException.java` | unchecked exceptions mapped to 400/404 | services | — | business errors as types | — | — | 03 (L) |
| `exception/ErrorResponse.java` | error JSON: timestamp, status, error, message, details, path, **requestId** (from MDC) | `GlobalExceptionHandler` | MDC | consistent error shape with correlation id | inconsistent errors | — | 03 (L) |
| `exception/GlobalExceptionHandler.java` | `@RestControllerAdvice` mapping: 404, 400 (validation, malformed JSON, type mismatch, bad request), 409 (integrity, lock failure), 503 (DB unavailable), framework statuses kept, 500 generic | every exception thrown by controllers | Spring MVC | no stack traces/internal text to clients | 500s with internals, wrong status codes | "What happens on DB outage mid-request?" | 03 (L) |
| `repository/*.java` (4) | Spring Data JPA interfaces; `findByIdForUpdate` with `@Lock(PESSIMISTIC_WRITE)` on `ProductRepository` and `OrderRepository` | services | Hibernate | derived queries + explicit row locks | overselling/double restock | "How do you prevent overselling?" | 03 (L) |
| `service/OrderService.java` | create order: validate user, lock products in ascending id order, check stock, deduct, compute total, save; status change: lock order, cancelled is final, restore stock once on cancel | `OrderController` | repositories | transaction + ordered locks = no oversell, no deadlock | data corruption | "Show me the two-buyers scenario." | 03 (L) |
| `service/ProductService.java` | CRUD; trims strings; delete + `flush()` to surface FK violation as 409 | `ProductController` | `ProductRepository` | — | 500 instead of 409 on delete | — | 03 (L) |
| `service/UserService.java` | list/get/create; email normalised `trim().toLowerCase(Locale.ROOT)` before uniqueness check | `UserController` | `UserRepository` | case-insensitive uniqueness | duplicates differing only by case | — | 03 (L) |
| `src/main/resources/application.properties` | port 8080, graceful shutdown 20 s, datasource defaults (local only, overridden by env), Hikari fail-fast timeouts, Flyway locations/baseline, `ddl-auto=validate`, `open-in-view=false`, CORS, ECS logging fields | Spring at startup | env vars `SPRING_DATASOURCE_*`, `CORS_ALLOWED_ORIGINS`, `APP_ENVIRONMENT`, `LOGGING_STRUCTURED_FORMAT_CONSOLE` | 12-factor: same jar everywhere, config from environment | wrong DB, hanging requests | "How does the app get DB credentials on EKS?" | 03 (L) |
| `db/migration/V1__initial_schema.sql` | 4 tables, PKs, unique email, FKs | Flyway on startup | MySQL / H2 | versioned schema | app cannot start (validate fails) | "Why Flyway?" | 04 (L) |
| `db/migration/V2__indexes_and_integrity_checks.sql` | 3 indexes; CHECK stock ≥ 0, price > 0, quantity > 0 | Flyway | V1 | DB-level guard for invariants | invariants only in code | "Why constraints if the API validates?" | 04 (L) |
| `db/seed/R__demo_data.sql` | repeatable migration inserting demo rows **only if `users` is empty** | Flyway, only when `classpath:db/seed` is added (Compose) | V1 | never touches real data; never on AWS | demo DB empty (harmless) | "What is a repeatable migration?" | 04 (L) |
| `src/test/.../ApiIntegrationTest.java` | 14 MockMvc tests over the real Spring context + H2: health, users, products, orders, cancellations, error mapping | `mvn verify` | `application-test.properties` | black-box tests of the real API | regressions undetected | "What do your tests cover?" | 03 (B) |
| `FailurePathWebTest.java` | 4 `@WebMvcTest` tests with mocked `DataSource`/`ProductService`: readiness 503 while liveness 200, DB outage → 503 without leaking host, lock timeout → 409, unexpected → generic 500 | `mvn verify` | Mockito | failure paths hard to trigger for real | — | — | 03 (L) |
| `OrderConcurrencyTest.java` | 8 threads buy 1 unit each of a product with stock 3; asserts exactly 3 orders, stock 0 | `mvn verify` | H2, real `OrderService` | proves the lock works (mutation-checked) | overselling undetected | "How do you test concurrency?" | 03 (L) |
| `RequestCorrelationTest.java` | 3 tests: generates an id, propagates a safe incoming id to header and error body, replaces unsafe ids | `mvn verify` | — | — | — | — | 03 (B) |
| `dto/ProductResponseTest.java` | parameterised test of `calculateStatus` boundaries | `mvn verify` | — | boundary values 0/1/10/11 | — | — | 03 (B) |
| `src/test/resources/application-test.properties` | H2 in-memory DB in MySQL mode for profile `test`; Flyway applies real migrations; `ddl-auto=validate` | tests with `@ActiveProfiles("test")` | H2 | isolated, fast, never touches a real DB | tests hit a real database | "Why H2 for tests?" | 03 (L) |

## 3.5 Application — frontend (`order-inventory-platform/frontend`)

| File | Purpose and important contents | Used by / when | Depends on | Design rationale | If wrong or missing | Likely viva question | Chapter |
|---|---|---|---|---|---|---|---|
| `package.json` | scripts `dev`, `build`, `preview`, `test` (vitest run), `lint` (`--max-warnings=0`), `test:coverage`; deps React 18, react-router-dom 7; dev deps Vite 8, Vitest 5, ESLint 9, Testing Library, jsdom; `engines.node >= 20.19.0` | npm locally, Docker build, Jenkins | npm registry | — | no build/tests | "Dependencies vs devDependencies?" | 02 (L) |
| `package-lock.json` | exact resolved dependency tree (5,728 lines) | `npm ci` | — | reproducible installs | non-reproducible builds | "Why npm ci?" | 02 (C) |
| `vite.config.js` | React plugin; dev server on 5173 with `/api` proxy to `VITE_DEV_API_PROXY` or `localhost:8080`; Vitest jsdom + setup + V8 coverage | `npm run dev/build/test` | — | dev mirrors production same-origin routing | API calls fail in dev | "Why a proxy in dev?" | 02 (L) |
| `eslint.config.js` | flat config: JS + React + hooks + refresh rules, `prop-types` off | `npm run lint` (CI) | ESLint plugins | catch bugs (hooks rules) early | lint stage fails/misses issues | — | 02 (L) |
| `index.html` | root `<div id="root">`, module script `/src/main.jsx`, Inter font, inline SVG favicon | Vite entry; served by nginx | — | SPA shell | blank page | — | 02 (L) |
| `Dockerfile` | `node:24-alpine` builds `dist/` with `npm ci && npm run build`; `nginxinc/nginx-unprivileged:1.30-alpine` serves it as UID 101 on 8080; `BACKEND_URL` default; templates rendered by envsubst | Compose, Jenkins | `nginx/*` | non-root nginx; same image for Compose and EKS | — | "Why nginx in the frontend container?" | 05 (L) |
| `.dockerignore` | excludes `node_modules/`, `dist/`, `coverage/`, `.env*`, keys | Docker build | — | — | huge context, stale builds | — | 05 (L) |
| `nginx/default.conf.template` | access log with `rid=$request_id`; `listen 8080`; runtime DNS `resolver`; gzip; `/healthz` 200; `/api/` reverse proxy to `${BACKEND_URL}` adding `X-Request-Id`; `/assets/` cached 1 year immutable; SPA fallback `try_files ... /index.html` with `no-cache` | nginx at container start (envsubst) | `BACKEND_URL`, `NGINX_LOCAL_RESOLVERS` | same image works in Compose/K8s; deep links work; new deployments load immediately | 404 on refresh, broken API proxy | "How does a deep link like /orders work?" | 02, 05 (L) |
| `nginx/security-headers.conf` | `X-Content-Type-Options nosniff`, `X-Frame-Options DENY`, `Referrer-Policy` | included in each location | — | nginx does not inherit `add_header` into locations that set their own | missing headers on some paths | — | 05 (L) |
| `sonar-project.properties` | project key, sources = `src`, tests and exclusions, LCOV path | `sonar-scanner` in Jenkins | `coverage/lcov.info` | coverage in Sonar | Sonar analysis misconfigured | — | 10 (L) |
| `src/main.jsx` | `createRoot` + `StrictMode` + `BrowserRouter` + `App` + CSS | browser on load | — | — | blank page | — | 02 (L) |
| `src/App.jsx` | routes: `/login`, layout with `/dashboard`, `/products`, `/orders`, `/users`, `/` → dashboard, `*` → dashboard | React Router | pages | layout route with `<Outlet/>` | navigation broken | "How is routing done?" | 02 (L) |
| `src/services/api.js` | `API_BASE_URL` (`VITE_API_BASE_URL` or `/api`), `request()` with JSON headers, 15 s timeout (`AbortController`), 204 → null, error message from `details`/`message`, non-JSON 2xx treated as error, friendly network/timeout messages; `healthApi`, `usersApi`, `productsApi`, `ordersApi` | every page | `fetch` | one place for HTTP behaviour | inconsistent error handling | "What happens on 503?" | 02 (L) |
| `src/hooks/useToasts.js` | toast list state; stable `addToast`/`removeToast` via `useCallback`; ids from a `useRef` counter; auto-dismiss 4 s | pages | React | stable callbacks avoid effect loops | duplicate keys / re-render loops | — | 02 (L) |
| `src/components/*.jsx` (8) | `Header` (title + API health badge polling `/api/health` every 15 s), `Sidebar` (NavLinks), `Modal` (Escape + overlay close), `ConfirmDialog`, `StatCard`, `StatusBadge` (order/stock badges), `Toast`, `Icons` (inline SVG) | pages | — | reusable presentational components | UI breaks | — | 02 (L; Icons C) |
| `src/pages/Dashboard.jsx` | loads users/products/orders with `Promise.allSettled`; KPIs; low stock (≤ 10); revenue excluding cancelled; recent 5 orders; error banner | route `/dashboard` | `api.js` | partial failure still shows data + error | — | — | 02 (B) |
| `src/pages/Products.jsx` | list, search, category filter, create/edit modal with validation, delete confirm; shows backend 409 message | `/products` | `productsApi` | — | — | — | 02 (B) |
| `src/pages/Orders.jsx` | list + filters; create-order modal with multiple lines, stock-aware validation and preview total; status modal (cancel warning, cancelled is final) | `/orders` | `ordersApi`, `usersApi`, `productsApi` | client validation for UX, server for truth | — | "Trace Create Order end to end." | 02 (L for logic, B for markup) |
| `src/pages/Users.jsx` | list, search, create with email regex validation, lower-cased email | `/users` | `usersApi` | — | — | — | 02 (B) |
| `src/pages/Login.jsx` | demo landing form; submit only navigates to `/dashboard` (**no authentication**) | `/login` | — | out of scope | — | "Is there authentication?" (answer: no) | 02 (L) |
| `src/index.css` | 889 lines of design tokens (CSS variables), layout, tables, badges, modals, toasts, spinner | browser | — | — | ugly UI only | — | 02 (C) |
| `src/test/setup.js`, `src/test/helpers.js` | jest-dom matchers + cleanup; `jsonResponse()` and `mockApi()` fetch router that fails on unexpected requests | Vitest | — | deterministic UI tests without a backend | flaky tests | — | 02 (L) |
| `src/**/*.test.js(x)` (4 files, 21 tests) | API client (7), routing/pages (5), workflows (7), hook (2) | `npm test` / Jenkins | helpers | — | — | "How are frontend tests different from backend tests?" | 02 (B) |

## 3.6 Application — local environment and logging

| File | Purpose and important contents | Used by / when | Depends on | Design rationale | If wrong or missing | Likely viva question | Chapter |
|---|---|---|---|---|---|---|---|
| `order-inventory-platform/docker-compose.yml` | `mysql:8.4` (named volume, healthcheck `mysqladmin ping`), `backend` (env DB URL, Flyway + seed locations, waits for healthy MySQL, healthcheck `/api/health/ready`), `frontend` (port 3000→8080, waits for healthy backend); bridge network | `docker compose up -d --build` | `.env` (optional) | ordered start via health conditions; data persists in a volume | stack does not start / data lost | "How does the backend find MySQL?" (service name `mysql`) | 05 (L) |
| `docker-compose.logging.yml` | overlay: backend ECS logs; Elasticsearch, Kibana (127.0.0.1 only), Filebeat (root, Docker socket read-only) | `docker compose -f docker-compose.yml -f docker-compose.logging.yml up -d` | `logging/*` | optional; security disabled → localhost only | — | — | 11 (L) |
| `.env.example` | placeholders for root/app DB passwords, host ports, image tag | copied to `.env` | — | no real secrets in Git | — | — | 05 (L) |
| `README.md` (platform) | local usage notes | humans | — | — | — | — | — |
| `database/README.md` | schema summary, baseline behaviour, how to add `V3__…` | humans | — | — | — | — | 04 |
| `logging/filebeat.yml` | Docker autodiscover for the 3 containers; decode JSON lines; add `app` field; ILM policy | Compose Filebeat | `ilm-policy.json` | — | — | — | 11 (L) |
| `logging/ilm-policy.json` | rollover 1 day / 1 GB, delete after 7 days | Filebeat setup | — | bounded storage | unbounded index growth | — | 11 (L) |
| `logging/kibana-saved-objects.ndjson` | data view `filebeat-*`, 4 saved searches, dashboard `oi-operations` | `kibana-setup.sh` | Kibana | dashboards as code | manual dashboard work | — | 11 (C) |
| `logging/kibana-setup.sh` | waits for Kibana `available`, imports the ndjson (`overwrite=true`) | manually / after resume | curl, node | idempotent import | — | — | 11 (L) |

## 3.7 Kubernetes and Helm

| File | Purpose and important contents | Used by / when | Depends on | Design rationale | If wrong or missing | Likely viva question | Chapter |
|---|---|---|---|---|---|---|---|
| `helm/order-inventory/Chart.yaml` | chart name/version 1.0.0, type application | Helm | — | — | no chart | — | 09 (L) |
| `values.yaml` | EKS defaults: image registry/tag (required), resources, replicas 2/2, rolling update 0/1, preStop 10 s, PDB min 1, ingress ALB annotations, config (CORS, ECS logs, JAVA_OPTS), `database.existingSecret: mysql-secret` | `helm upgrade` | — | one chart, environment overrides | — | "What does maxUnavailable 0 mean?" | 09 (L) |
| `values-minikube.yaml` | registry `local`, no Ingress, smaller resources | minikube acceptance test | — | — | — | — | 09 (L) |
| `templates/_helpers.tpl` | labels; `oi.image` fails without tag or with `latest`; pod security context (non-root, seccomp) | all templates | values | guardrails in templates | mutable deploys possible | "How do you forbid latest?" | 09 (L) |
| `templates/backend.yaml` | Deployment (probes, preStop, read-only root fs, Secret env, ConfigMap env, config checksum) + Service (ALB health-check path `/api/health`) | Helm | Secret `mysql-secret`, ConfigMap | — | — | — | 09 (L) |
| `templates/frontend.yaml` | Deployment (FQDN `BACKEND_URL`, `/healthz` probes) + Service port 80 → 8080 | Helm | — | — | — | — | 09 (L) |
| `templates/configmap.yaml` | `backend-config`: `APP_ENVIRONMENT`, `CORS_ALLOWED_ORIGINS`, `JAVA_OPTS`, optional `LOGGING_STRUCTURED_FORMAT_CONSOLE` | backend `envFrom` | values | non-secret config separated from secrets | — | — | 09 (L) |
| `templates/ingress.yaml` | (if enabled) Ingress class `alb`: `/api` → backend:8080, `/` → frontend:80 | AWS Load Balancer Controller | annotations | path routing on one ALB | no ALB | "How does an Ingress become an ALB?" | 09 (L) |
| `templates/pdb.yaml` | PDB per app, `minAvailable: 1` | node drains/upgrades | — | voluntary disruptions keep 1 pod | — | — | 09 (L) |
| `templates/NOTES.txt` | message printed after install/upgrade | Helm | — | — | — | — | 09 (L) |
| `k8s/namespace.yaml` | Namespace `order-inventory` | bootstrap and local test | — | — | — | — | 09 (L) |
| `k8s/iam_policy.json` | upstream AWS Load Balancer Controller IAM policy (v3.6.0) | Terraform `aws_iam_policy.lbc` | — | copied from upstream, kept in Git | controller cannot create ALBs | — | 06 (C) |
| `k8s/logging/elk.yaml` | namespace `logging`; Elasticsearch (non-root, read-only rootfs, init copy of config, emptyDir); Kibana; Filebeat RBAC, ConfigMap, DaemonSet (root, read-only host log mounts, `DAC_READ_SEARCH`) | `kubectl apply` (cluster admin) | worker nodes | demo-sized logging without extra AWS cost | no central logs | — | 11 (L) |
| `k8s/testing/mysql-test-fixture.yaml` | namespace `oi-testdb`, PVC, MySQL 8.4 Deployment, Service — local tests only | `scripts/k8s-acceptance-test.sh` | Secret created by the script | realistic DB outage tests on minikube | — | — | 09 (B) |

## 3.8 Terraform (`terraform/`)

| File | Purpose and important contents | Used by / when | Depends on | Design rationale | If wrong or missing | Likely viva question | Chapter |
|---|---|---|---|---|---|---|---|
| `backend.tf` | S3 backend: bucket `order-inventory-tfstate-038215676861`, key, region, `encrypt`, `use_lockfile = true` | `terraform init` | bootstrap bucket | shared, encrypted, locked state | local state, no locking | "Where is your state and how is it locked?" | 06 (L) |
| `main.tf` | providers, VPC, subnets (public/private/database), IGW, NAT + EIP, route tables, ECR (immutable) + lifecycle, EKS SG/role/cluster (KMS secrets, endpoint access), node role + node group (`ignore_changes` desired size), OIDC, EBS CSI role, LBC role, add-ons, RDS SG/rule/subnets/route table, random password, Secrets Manager, subnet group, parameter group, RDS instance | `plan/apply` | variables, `kms.tf`, `monitoring.tf` (log groups) | — | — | many | 06 (L) |
| `jenkins.tf` | Jenkins SG + admin-only rules, EKS API rule from Jenkins SG, IAM role/policies (ECR push to 2 repos, describe cluster, put CI reports), instance profile, Ubuntu 24.04 AMI lookup, EC2 (IMDSv2, encrypted gp3 30 GB, `ignore_changes [ami, associate_public_ip_address]`), EKS access entry (edit, namespace-scoped), generated Jenkins/SonarQube admin passwords → Secrets Manager | apply | `main.tf` | least privilege, no stored AWS keys | — | "Why ignore_changes on the instance?" | 06 (L) |
| `kms.tf` | customer-managed KMS key (rotation on, 7-day deletion window) + alias + policy for CloudWatch/Budgets/SNS; EKS cluster role permission | apply | — | SNS encryption usable by CloudWatch; EKS secret envelope encryption | alarms silently undelivered / secrets unencrypted | — | 06 (L) |
| `storage.tf` | CI-reports bucket: private, owner-enforced, SSE-S3, versioned, 30-day expiry, TLS-only | apply; Jenkins uploads | — | bounded cost, secure defaults | — | — | 06 (L) |
| `monitoring.tf` | SNS topic (KMS) + policy, SQS audit queue + subscription, optional email, 9 alarms (RDS ×5, Jenkins ×2, nodes ×1, NAT ×1), RDS log groups (14 days), monthly budget | apply | `kms.tf` | verifiable alert delivery without email | no alerting | — | 11, 06 (L) |
| `variables.tf` | all inputs with defaults and validations (`0.0.0.0/0` rejected) | Terraform | — | guardrails as code | unsafe values accepted | — | 06 (L) |
| `outputs.tf` | 22 outputs (IDs, endpoints, ECR URLs, LBC role, RDS address, Jenkins ID/IP/URL, buckets, SNS ARN, DB secret ARN, SQS URL) | scripts (`tfout`), humans | — | scripts read real IDs instead of hard-coding | scripts cannot find resources | — | 06 (L) |
| `terraform.tfvars` | region, project, env, VPC/public/private CIDRs, AZs (non-secret) | auto-loaded | — | — | — | — | 06 (L) |
| `environments/full.tfvars` | full profile: Jenkins on, 2 nodes (min 0, max 3), t3.large Jenkins, budget $350 (placeholder admin CIDR) | `-var-file` | — | profiles as files | — | — | 06 (L) |
| `environments/learning.tfvars` | cheaper profile: no Jenkins, 1 node, 1-day backups, budget $100 | `-var-file` | — | — | — | — | 06 (L) |
| `.terraform.lock.hcl`, `bootstrap/.terraform.lock.hcl` | provider version + checksum locks | `terraform init` | — | reproducible providers | provider drift | "What is the lock file?" | 06 (C) |
| `bootstrap/main.tf` | creates the state bucket: versioning, AES256, public access block, TLS-only policy; local state | once, before the main stack | — | chicken-and-egg of remote state | — | "How was the state bucket created?" | 06 (L) |

## 3.9 Ansible (`ansible/`)

| File | Purpose and important contents | Used by / when | Depends on | Design rationale | If wrong or missing | Likely viva question | Chapter |
|---|---|---|---|---|---|---|---|
| `ansible.cfg` | inventory path, roles path, host key checking on, pipelining | ansible-playbook | — | — | — | — | 07 (L) |
| `group_vars/all.yml` | pinned tool versions (Maven 3.9.12, Node 24.22.0, Trivy 0.76.0, Helm 4.3.1, kubectl 1.36.5, Terraform 1.15.8, SonarScanner 8.1.0.6389), Jenkins port, `docker_start_service` | playbook (`vars_files`) | — | same versions as `ci/jenkins/Dockerfile` | toolchain drift | — | 07 (L) |
| `inventory.example.ini` | template host line | copied to `inventory.ini` (ignored) | — | — | — | — | 07 (L) |
| `requirements.yml` | collections `community.docker`, `ansible.posix`, `community.general` | `ansible-galaxy` | — | — | modules missing | — | 07 (L) |
| `playbooks/jenkins.yml` | host group `jenkins`, `become`, roles in order with conditions (`git_mirror` only for local checkout, `sonarqube`/`jenkins_casc` only when passwords given), post-task version banner | ansible-playbook | roles | — | — | — | 07 (L) |
| `run-playbook.sh` | runs Ansible in a `python:3.12-slim` container; host from `terraform output jenkins_public_ip`; secrets from Secrets Manager streamed as JSON on stdin; builds a temporary inventory | operator | Docker, AWS CLI, Terraform, SSH key | no local Ansible needed on Windows | — | "How do secrets reach the Jenkins host?" | 07 (L) |
| `roles/common/*` | base packages, unattended upgrades, SSH hardening (validated with `sshd -t`), reload handler | playbook | — | — | — | — | 07 (L) |
| `roles/docker/tasks/main.yml` | `docker.io`, service enabled | playbook | — | — | — | — | 07 (L) |
| `roles/build_tools/*` | JDK 21, Maven, Node, SonarScanner (unarchive with `creates`), symlinks, version checks for single-binary tools, Trivy/Helm/kubectl/Terraform/AWS CLI only when the version differs | playbook | `group_vars` | idempotent installs | — | "How is idempotency achieved?" | 07 (L) |
| `roles/jenkins/*` | Jenkins LTS apt repo (deb822, pinned key), install, docker group, systemd drop-in dir, start, wait for `/login`; restart handler | playbook | — | — | — | — | 07 (L) |
| `roles/git_mirror/tasks/main.yml` | bare repo `/srv/git/devops-project.git`, `safe.directory` | only when local checkout is enabled (historical) | — | used before the GitHub history was cleaned | — | — | 07 (L) |
| `roles/sonarqube/*` | sysctl for embedded Elasticsearch, SonarQube container on `127.0.0.1:9000` with volumes, wait UP, replace factory password, generate token into `/etc/jenkins-secrets/sonar_token` (`no_log`) | playbook | Docker | private SonarQube | — | — | 07 (L) |
| `roles/jenkins_casc/*` + `templates/casc.yaml.j2` | plugin manager + plugin list, render JCasC (admin user, matrix auth, global env, Sonar credential, pipeline job with `pollSCM` and repo URL), secrets env file `root:jenkins 0640`, systemd override (no setup wizard), wait for the job API | playbook | SonarQube token | Jenkins fully reproducible from code | manual click-ops | "What is JCasC?" | 07 (L) |
| `test/test-in-container.sh` | runs syntax check, ansible-lint, apply, second apply (must be `changed=0`) in a systemd Ubuntu 24.04 container | developer | Docker | test playbook without AWS | — | "How did you test Ansible?" | 07 (L) |

## 3.10 CI (local) and scripts

| File | Purpose and important contents | Used by / when | Depends on | Design rationale | If wrong or missing | Likely viva question | Chapter |
|---|---|---|---|---|---|---|---|
| `ci/docker-compose.ci.yml` | local SonarQube (127.0.0.1:19000) + Jenkins (127.0.0.1:18090), repo mounted read-only, Docker socket (local only) | `ci/start-local-ci.sh` | `ci/.env` | run the same Jenkinsfile without AWS (`DEPLOY=false`) | — | — | 08 (L) |
| `ci/jenkins/Dockerfile` | Jenkins LTS + pinned toolchain + plugins + JCasC | local CI | `plugins.txt`, `casc.yaml` | reference toolchain | — | — | 08 (L) |
| `ci/jenkins/casc.yaml`, `plugins.txt` | local JCasC (job with `DEPLOY=false` default), plugin list | local Jenkins | — | — | — | — | 08 (L) |
| `ci/start-local-ci.sh` | generates passwords into `ci/.env`, starts SonarQube, replaces factory password, creates token, starts Jenkins | developer | Docker, node | secrets never printed | — | — | 08 (L) |
| `scripts/deploy-k8s.sh` | Helm upgrade with immutable tag, namespace-scoped preflight, Secret check, records previous good revision, `--wait`, rollout check, **rollback on failure** | Jenkins "Deploy to EKS", resume, tests | Helm, kubectl | single deploy path for CI, tests and resume | no automatic rollback | "How does rollback work?" | 08/09 (L) |
| `scripts/smoke-test.sh` | 20 functional checks (or 8 read-only with `SMOKE_READ_ONLY=1`) through any base URL | Jenkins, resume, humans | curl, node | proves the deployed system end to end | — | — | 08 (L) |
| `scripts/create-db-secret.sh` | reads Secrets Manager JSON and creates Secret `mysql-secret` (`url` with `sslMode=REQUIRED`, `username`, `password`) without printing | cluster bootstrap / rotation | AWS CLI, Terraform output | secret never on disk | backend cannot connect | — | 09 (L) |
| `scripts/install-lb-controller.sh` | Helm install of AWS Load Balancer Controller 3.6.0 with the IRSA role | cluster bootstrap | Terraform outputs | — | no ALB | — | 09 (L) |
| `scripts/create-alb-alarms.sh` | alarms for the controller-created ALB: ELB 5xx, target 5xx, and one unhealthy-hosts alarm per target group (4 in total with 2 target groups) | after deploy, resume | SNS ARN, Ingress | ALB is not Terraform-managed | — | — | 11 (L) |
| `scripts/aws-zero-downtime-test.sh` | load generator + 5 scenarios on real EKS through the ALB | manual test | deploy-k8s, smoke-test | evidence of zero downtime | — | "How did you prove zero downtime?" | 09 (L) |
| `scripts/k8s-acceptance-test.sh` | same on minikube incl. DB outage and pod loss | manual test | MySQL fixture | — | — | — | 09 (B) |
| `scripts/compose-acceptance-test.sh` | Compose: build/start, smoke, persistence, DB outage, crash restart | manual test | Compose | — | — | — | 05 (B) |
| `scripts/lib/evaluation-common.sh` | shared helpers for suspend/resume (logging, `die`, `wait_until`, preflight, state queries, predicates) | sourced | AWS CLI, Terraform, kubectl | — | — | — | 12 (L) |
| `scripts/suspend-evaluation.sh` / `.ps1` | suspend (7 stages, `--plan`) / PowerShell wrapper | operator | lib | — | — | — | 12 (L) |
| `scripts/resume-evaluation.sh` / `.ps1` | resume (11 stages) / wrapper | operator | lib, manifest | — | — | — | 12 (L) |
| `aws/iam/order-inventory-deployer-iam.json` | inline policy `order-inventory-iam-scope` for the deployer: IAM write only on `order-inventory-*` roles/policies/profiles, OIDC providers for EKS, service-linked roles for 5 services (attached alongside AWS-managed `PowerUserAccess` + `IAMReadOnlyAccess`, verified 2026-10-25) | IAM | — | PowerUser cannot manage IAM; this scopes the IAM it needs | Terraform cannot create roles | "Why not AdministratorAccess?" | 10 (L) |

## 3.11 Documentation

| File | Content |
|---|---|
| `docs/API.md` | endpoint table, status codes, captured examples |
| `docs/ARCHITECTURE.md` | runtime, CI/CD, data model diagrams; key decisions |
| `docs/AWS_DEPLOYMENT.md` | deployment record, resource inventory, cost, verification table, Jenkins source of truth, teardown |
| `docs/OPERATIONS_CHECKLIST.md` | release/deploy/provision/teardown/periodic checklists |
| `docs/RUNBOOKS.md` | §1–§10 runbooks (local, provision, deploy, rollback, recovery, tracing, DB ops, teardown, SonarQube, suspend/resume) |
| `docs/SECURITY.md` | secret handling, history remediation, rotation, hardening, accepted risks, credential status |
| `docs/TESTING.md` | every test and its result with status labels |
| `docs/recovery/evaluation-manifest.json` | recovery manifest written by suspend/resume (no secrets) |
| `docs/COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md`, `docs/EVALUATION_DAY_CHEAT_SHEET.md`, `docs/handbook/*` | this handbook |

## 3.12 Generated, third-party and evidence files (explained by category)

| Files | Category | Why no line-by-line teaching |
|---|---|---|
| `frontend/package-lock.json` | generated by npm | machine-written dependency graph with integrity hashes; regenerate with `npm install`, never hand-edit |
| `terraform/.terraform.lock.hcl`, `terraform/bootstrap/.terraform.lock.hcl` | generated by `terraform init` | provider versions + checksums; update with `terraform init -upgrade` |
| `k8s/iam_policy.json` | third-party (AWS) | the official AWS Load Balancer Controller policy; changing it by hand risks breaking the controller. It grants EC2/ELB describe/create/modify actions needed to manage ALBs, target groups, security groups and tags |
| `frontend/src/index.css` | styling | presentation only; no behaviour except class names used by components |
| `frontend/src/components/Icons.jsx` | inline SVG paths | drawing coordinates, not logic |
| `logging/kibana-saved-objects.ndjson` | exported Kibana objects | generated by Kibana export; edited only through Kibana |
| `docs/evidence/*.txt` (9 files) | recorded command output | evidence, not code; each is cited where its result is used (`aws-zero-downtime-2026-10-19.txt`, `aws-rds-interruption-2026-10-19.txt`, `elk-eks-2026-10-19.txt`, `jenkins-github-build-7-…`, `jenkins-github-poll-build-8-…`, `jenkins-local-build-3.txt`, `k8s-acceptance-2026-10-18.txt`, `k8s-final-state.txt`, `ansible-container-test-2026-10-18.txt`) |

## 3.13 Coverage checklist

Every tracked file appears in §3.3–§3.12. Files marked **L** are explained line by line (or in small
logical blocks) in the named chapter; **B** files (long JSX markup and test files with many similar cases)
are explained block by block with every behaviour listed; **C** files are explained by category above.
Known stale comments found while writing this handbook (documentation only; behaviour is correct):

| File | Stale text | Reality |
|---|---|---|
| `terraform/main.tf` lines 18–19 | "State is local by default … see backend.tf.example" | `terraform/backend.tf` configures the S3 backend; there is no `backend.tf.example` |
| `.gitignore` lines 53–55 | secrets "(db_password, alert_email) are passed via TF_VAR_*" | the DB password is now generated by Terraform (`random_password.db_master`); only `alert_email` is optional input |
| `ansible/run-playbook.sh` line 9–10 | default `JENKINS_REPO_URL` described as needed "while GitHub carries the pre-remediation history" | history was cleaned and pushed on 2026-10-19; the job uses GitHub (`JENKINS_REPO_URL=https://github.com/SamruddhiDoke/DevOps-Project.git` must be passed when re-running) |
| `docs/ARCHITECTURE.md` runtime diagram | `sns → Email` | no email is subscribed; delivery goes to the SQS audit queue |
| `frontend/src/components/Sidebar.jsx` | footer tag "Base Application (Phase 1)" | cosmetic label from the first project phase |
