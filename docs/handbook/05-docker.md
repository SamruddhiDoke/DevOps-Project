# Part 8 — Docker and Docker Compose

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md)

## 5.1 What Docker does (and does not do) in this project

*In general:* a **container image** is a read-only, layered filesystem plus start-up metadata; a
**container** is a process started from it, isolated with Linux namespaces and limited with cgroups,
**sharing the host kernel**. A virtual machine instead runs a whole guest OS on virtualised hardware.
Containers start in seconds and are small; VMs give stronger isolation.

In this project Docker:
- builds reproducible images for the backend and frontend (the same images run in Compose, minikube and EKS);
- runs the local full stack (MySQL + backend + frontend) and optional ELK with Docker Compose;
- runs the local CI controller and the Ansible controller (`ansible/run-playbook.sh`) as throwaway containers.

Docker does **not** schedule containers across machines, restart them on other hosts, load-balance or do
rolling updates on AWS — that is Kubernetes (EKS). It also does not scan images itself (Trivy does) or store
them centrally (ECR does).

## 5.2 Backend `Dockerfile` (line by line)

```dockerfile
FROM maven:3.9-eclipse-temurin-17-alpine AS builder
```
Stage 1 ("builder"): an image with Maven and JDK 17. Named so stage 2 can copy from it.

```dockerfile
WORKDIR /app
COPY pom.xml .
RUN mvn -B dependency:go-offline
```
Copy **only** `pom.xml` first and download all dependencies. Docker caches each instruction as a layer; as
long as `pom.xml` is unchanged, this slow layer is reused and a code-only change rebuilds in seconds.
`-B` = batch mode (no colours/prompts, CI-friendly).

```dockerfile
COPY src ./src
RUN mvn -B clean package -DskipTests
```
Copy sources and build the fat JAR. Tests are skipped here because Jenkins already ran them in "Backend Tests"
against the same commit (comment in the file); running them twice would only slow the build.

```dockerfile
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
```
Stage 2: a **JRE-only** Alpine image (no Maven, no compiler, no source code) — smaller and with fewer
packages that could contain vulnerabilities. Only what stage 2 copies ends up in the final image.

```dockerfile
RUN apk upgrade --no-cache \
 && addgroup -S -g 10001 app && adduser -S -u 10001 -G app app
```
Apply Alpine security fixes published after the base image was built (this removed findings that made the
Trivy gate fail before), and create an unprivileged system user/group with fixed id 10001.

```dockerfile
COPY --from=builder --chown=app:app /app/target/*.jar app.jar
USER 10001:10001
```
Copy the JAR from stage 1, owned by the app user. Run as **numeric** UID 10001: Kubernetes'
`runAsNonRoot: true` can only verify a numeric user (a name could map to root).

```dockerfile
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"
EXPOSE 8080
```
Heap = 75 % of the **container's** memory limit (1 GiB limit on EKS → ~768 MiB heap), leaving room for
metaspace/threads. On OutOfMemoryError the JVM exits so the orchestrator restarts it, instead of limping on.
`EXPOSE` documents the port (it does not publish it).

```dockerfile
HEALTHCHECK --interval=15s --timeout=3s --start-period=60s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/api/health > /dev/null || exit 1
```
Docker-level health check (used by plain Docker; Compose overrides it with `/api/health/ready`; Kubernetes
ignores `HEALTHCHECK` and uses its own probes). 60 s start period for JVM start-up.

```dockerfile
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
```
`sh -c` expands `$JAVA_OPTS`; `exec` **replaces** the shell with the JVM so Java is PID 1 and receives
`SIGTERM` directly on `docker stop` / pod termination → Spring's graceful shutdown runs. Without `exec`, the
shell would get the signal and the JVM would be killed after the grace period.

`.dockerignore` excludes `.git`, `target/`, IDE files, logs, `.env*`, `*.pem`, `*.key`, `README.md` from the
**build context** (the files sent to the Docker daemon): faster builds and no secrets copied into a layer.

## 5.3 Frontend `Dockerfile` (line by line)

```dockerfile
FROM node:24-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build
```
Same caching idea: dependencies from `package.json` + `package-lock.json` first. `npm ci` installs **exactly**
the lock file (fails if it does not match `package.json`) — reproducible; `--no-audit --no-fund` keeps CI
output quiet (Trivy and `npm audit` are run separately). `npm run build` writes `dist/`.

```dockerfile
FROM nginxinc/nginx-unprivileged:1.30-alpine
USER root
RUN apk upgrade --no-cache
USER 101
```
Runtime: the **unprivileged** nginx image runs as UID 101 and listens on 8080 (ports < 1024 need root).
Temporarily root only to apply package updates.

```dockerfile
ENV BACKEND_URL=http://backend:8080 \
    NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
```
Default upstream for `/api` = the Compose service name `backend`. `NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1` asks
the image's entrypoint to export the container's DNS server(s) from `/etc/resolv.conf` as
`NGINX_LOCAL_RESOLVERS`, used by the `resolver` directive in the template.

```dockerfile
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY nginx/security-headers.conf /etc/nginx/snippets/security-headers.conf
COPY --from=builder /app/dist /usr/share/nginx/html
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 CMD wget -qO- http://127.0.0.1:8080/healthz > /dev/null || exit 1
```
The official nginx image renders every `/etc/nginx/templates/*.template` with `envsubst` at start-up into
`/etc/nginx/conf.d/`, substituting **only variables that exist in the environment** — so nginx's own
`$uri`, `$host` etc. stay untouched. The built SPA becomes the web root.

## 5.4 nginx configuration (`frontend/nginx/default.conf.template`)

| Lines | Directive | Purpose |
|---|---|---|
| 6–7, 10 | `log_format with_request_id … rid=$request_id` / `access_log` | every access line contains nginx's per-request id, which is also sent to the backend → one id in both logs |
| 11–14 | `listen 8080`, `root`, `server_tokens off` | unprivileged port; hide the nginx version |
| 18 | `resolver ${NGINX_LOCAL_RESOLVERS} valid=10s ipv6=off` | resolve the backend name **at request time** (cached 10 s) rather than once at start-up, so nginx starts even if the backend is not up yet and follows IP changes |
| 20–22 | `gzip …` | compress text assets > 1 KB |
| 24 | `include …/security-headers.conf` | `nosniff`, `X-Frame-Options DENY` (no clickjacking), `Referrer-Policy` |
| 27–31 | `location = /healthz { return 200 "ok\n"; }` | probe endpoint independent of the backend (frontend liveness/readiness + ALB health check) |
| 36–47 | `location /api/` → `set $backend_upstream ${BACKEND_URL}; proxy_pass $backend_upstream;` + headers `Host`, `X-Request-Id $request_id`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`; connect timeout 5 s, read timeout 30 s | same-origin API for Compose/port-forward; using a **variable** in `proxy_pass` forces runtime DNS resolution |
| 50–55 | `location /assets/` → `expires 1y`, `Cache-Control "public, immutable"`, `try_files $uri =404` | hashed filenames can be cached forever; missing asset = real 404 |
| 58–62 | `location /` → `Cache-Control "no-cache"`, `try_files $uri $uri/ /index.html` | SPA fallback for deep links; `index.html` always revalidated so new releases load immediately |

Security headers are included again in each `location` that sets its own `add_header`, because nginx does
not inherit server-level `add_header` into such blocks (comment in `security-headers.conf`).

## 5.5 Docker Compose (`order-inventory-platform/docker-compose.yml`)

| Service | Key settings | Explanation |
|---|---|---|
| `mysql` | `image: mysql:8.4`, `restart: unless-stopped`, env `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE=order_inventory_db`, `MYSQL_USER`/`MYSQL_PASSWORD` (from `.env` or local defaults), `ports: "${MYSQL_HOST_PORT:-3307}:3306"`, volume `inventory-mysql-data:/var/lib/mysql`, healthcheck `mysqladmin ping` (10 s, 12 retries, 30 s start period) | The app uses a **non-root application account** limited to its database. Host port 3307 avoids clashing with a local MySQL on 3306. The **named volume** keeps data across `docker compose down`/`up` (only `down -v` deletes it). |
| `backend` | `build: ./backend`, `image: inventory-backend:${IMAGE_TAG:-local}`, `ports: 8080:8080`, env `SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/…`, user/password, `SPRING_FLYWAY_LOCATIONS=classpath:db/migration,classpath:db/seed`, `APP_ENVIRONMENT=local`, `depends_on: mysql: condition: service_healthy`, healthcheck `/api/health/ready` | **Service discovery**: on the user-defined bridge network, Docker's DNS resolves the service name `mysql` to the MySQL container. The backend starts only after MySQL is healthy; its own health requires the DB. Demo data is seeded locally only. |
| `frontend` | `build: ./frontend`, `ports: "${FRONTEND_HOST_PORT:-3000}:8080"`, `BACKEND_URL=http://backend:8080`, `depends_on: backend: condition: service_healthy` | Container port 8080 is published on host port 3000 → http://localhost:3000. |
| networks / volumes | `inventory-network` (bridge), `inventory-mysql-data` | isolated network for the three services; persistent data |

**Container port vs host port:** `"3000:8080"` = host port 3000 forwards to container port 8080. Inside the
network, containers talk to each other on container ports (`backend:8080`), never via host ports.

**Restart policy:** `unless-stopped` restarts a crashed container (verified: JVM killed from inside → restart
count 0 → 1 in `compose-acceptance-test.sh`); it does not restart a container stopped by the user.

**Start order and readiness:** `depends_on` with `condition: service_healthy` waits for the health check,
not just for the container to start. MySQL health = server answers; backend health = DB reachable.

`.env.example` documents the variables (placeholders `change-me-*`); copy it to `.env` (git-ignored).

### Local commands

```powershell
cd order-inventory-platform
Copy-Item .env.example .env                 # optional: set your own local passwords/ports
docker compose up -d --build                # build images and start mysql, backend, frontend
docker compose ps                           # all three "healthy"
docker compose logs -f backend              # follow backend logs (Ctrl+C to stop following)
Invoke-RestMethod http://localhost:3000/api/health/ready
bash ../scripts/smoke-test.sh http://localhost:3000            # 20 functional checks (Git Bash)
docker compose -f docker-compose.yml -f docker-compose.logging.yml up -d   # optional ELK, Kibana on http://localhost:5601
docker compose stop                         # stop, keep containers and data
docker compose down                         # remove containers and network, KEEP the data volume
# docker compose down -v                    # would DELETE the database volume - do not use routinely
```

Tests in containers: backend `mvn -B verify` and frontend `npm test` run on the host or in Jenkins, not in
Compose. `scripts/compose-acceptance-test.sh` runs the whole Compose scenario (build, health, smoke test,
persistence across recreation, DB outage → readiness/API 503 while liveness 200 → automatic recovery, crash
auto-restart, clean stop with the volume kept): **8/8 VERIFIED** (`docs/TESTING.md`).

## 5.6 Image tagging and scanning

| Context | Tag | Example |
|---|---|---|
| Compose | `inventory-backend:${IMAGE_TAG:-local}` | `inventory-backend:local` |
| Jenkins local name | `order-inventory-<svc>:<build>-<commit>` | `order-inventory-backend:8-18a2bc6` |
| ECR | `<account>.dkr.ecr.ap-south-1.amazonaws.com/order-inventory-<svc>:<build>-<commit>` | `…/order-inventory-backend:8-18a2bc6` |

Jenkins also labels images with `org.opencontainers.image.revision=<full commit>` and
`org.opencontainers.image.version=<tag>`. Trivy scans every image before it is pushed (fixable HIGH/CRITICAL
fail the build) and ECR scans again on push. Latest results: 0 vulnerabilities in both images (Trivy 0.76.0,
Alpine 3.24.2 — `docs/TESTING.md`); this means no **known, fixable** CVEs in the scanned packages at scan
time, not that the images are free of all vulnerabilities.

## 5.7 Local vs production containers

| Aspect | Compose | EKS |
|---|---|---|
| Database | MySQL container, plaintext (`useSSL=false`) on a private bridge network | RDS, TLS required |
| Health checks | Docker `healthcheck` (backend: readiness) | Kubernetes startup/liveness/readiness probes |
| Restart | `restart: unless-stopped` | Deployment/ReplicaSet controllers recreate pods anywhere |
| Filesystem | writable | backend `readOnlyRootFilesystem: true` + `/tmp` emptyDir; all capabilities dropped |
| Config/secrets | `.env`, environment | ConfigMap + KMS-encrypted Secret |
| Logs | plain text (ECS JSON with the logging overlay) | ECS JSON → Filebeat → Elasticsearch |
| Images | built locally | pulled from ECR by immutable tag |

## 5.8 Viva questions

| Question | Answer |
|---|---|
| Why multi-stage builds? | The final image contains only the runtime and the artefact, not build tools or source: smaller, faster to pull, fewer CVEs. |
| Why copy `pom.xml`/`package*.json` before the source? | Layer caching: dependencies are only downloaded again when the dependency files change. |
| Why non-root and a numeric UID? | Limits damage if the app is compromised; Kubernetes `runAsNonRoot` needs a numeric UID to verify. |
| Why `exec` in the entrypoint? | So the JVM is PID 1 and receives SIGTERM for graceful shutdown. |
| Container vs VM? | Container = isolated process sharing the host kernel; VM = full guest OS on a hypervisor. |
| How does the backend find MySQL in Compose? | Docker's embedded DNS resolves the service name `mysql` on the shared bridge network. |
| What does `depends_on: condition: service_healthy` add? | Waits for the dependency's health check to pass, not just for it to start. |
| Is a scan with 0 findings proof of security? | No: it means no known vulnerabilities (fixable ones for the gate) in the scanned components at that time. |
