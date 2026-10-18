package com.example.orderinventory.controller;

import com.example.orderinventory.dto.HealthResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import javax.sql.DataSource;
import java.sql.Connection;

@RestController
@RequestMapping("/api/health")
public class HealthController {

    private static final Logger log = LoggerFactory.getLogger(HealthController.class);
    private static final int DB_VALIDATION_TIMEOUT_SECONDS = 2;

    private final DataSource dataSource;

    public HealthController(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /**
     * Liveness: the process is up and serving HTTP. Used by the ALB health check and
     * Kubernetes liveness/startup probes, so it must not depend on the database.
     */
    @GetMapping
    public ResponseEntity<HealthResponse> getHealth() {
        return ResponseEntity.ok(new HealthResponse("UP"));
    }

    /**
     * Readiness: the service can actually serve API requests (database reachable).
     * Used by the Kubernetes readiness probe and deployment verification.
     */
    @GetMapping("/ready")
    public ResponseEntity<HealthResponse> getReadiness() {
        try (Connection connection = dataSource.getConnection()) {
            if (connection.isValid(DB_VALIDATION_TIMEOUT_SECONDS)) {
                return ResponseEntity.ok(new HealthResponse("UP", "UP"));
            }
            log.warn("Readiness check failed: database connection is not valid");
        } catch (Exception ex) {
            log.warn("Readiness check failed: database unreachable ({})", ex.getClass().getSimpleName());
        }
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(new HealthResponse("DOWN", "DOWN"));
    }
}
