# ==========================================
# Stage 1: Build the Spring Boot application
# ==========================================
FROM maven:3.9-eclipse-temurin-17-alpine AS builder

WORKDIR /app

# Copy pom.xml and download dependencies first for layer caching
COPY pom.xml .
RUN mvn -B dependency:go-offline

# Copy source code and build the application JAR.
# Tests run in the CI "Backend Tests" stage, so they are skipped here.
COPY src ./src
RUN mvn -B clean package -DskipTests

# ==========================================
# Stage 2: Lightweight runtime environment
# ==========================================
FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

# Pick up Alpine security fixes released after the base image was built,
# then create an unprivileged user
RUN apk upgrade --no-cache \
 && addgroup -S -g 10001 app && adduser -S -u 10001 -G app app

# Copy built jar from the builder stage
COPY --from=builder --chown=app:app /app/target/*.jar app.jar

# Numeric UID so Kubernetes runAsNonRoot can verify the user
USER 10001:10001

# Size the heap from the container memory limit; extra flags can be passed via JAVA_OPTS
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"

# Expose backend port
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=60s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/api/health > /dev/null || exit 1

# exec so the JVM is PID 1 and receives SIGTERM for graceful shutdown
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
