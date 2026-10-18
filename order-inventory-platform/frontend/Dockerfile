# ==========================================
# Stage 1: Build the React + Vite frontend
# ==========================================
FROM node:24-alpine AS builder

WORKDIR /app

# Copy package files for dependency caching
COPY package*.json ./

# Install dependencies exactly as locked
RUN npm ci --no-audit --no-fund

# Copy application source code
COPY . .

# Build static production bundle into /app/dist
RUN npm run build

# ==========================================
# Stage 2: Serve static assets with unprivileged Nginx (runs as non-root, listens on 8080)
# ==========================================
FROM nginxinc/nginx-unprivileged:1.30-alpine

# Pick up Alpine security fixes released after the base image was built
USER root
RUN apk upgrade --no-cache
USER 101

# Backend location for the /api reverse proxy. The Docker Compose service name works as-is;
# Kubernetes sets the fully-qualified Service DNS name (nginx's resolver ignores search domains).
ENV BACKEND_URL=http://backend:8080 \
    NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1

# SPA + reverse-proxy configuration (rendered by the image's envsubst entrypoint)
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY nginx/security-headers.conf /etc/nginx/snippets/security-headers.conf

# Copy compiled static files from builder stage
COPY --from=builder /app/dist /usr/share/nginx/html

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz > /dev/null || exit 1
