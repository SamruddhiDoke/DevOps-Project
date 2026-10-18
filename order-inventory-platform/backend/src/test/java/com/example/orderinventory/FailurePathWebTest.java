package com.example.orderinventory;

import com.example.orderinventory.controller.HealthController;
import com.example.orderinventory.controller.ProductController;
import com.example.orderinventory.exception.GlobalExceptionHandler;
import com.example.orderinventory.service.ProductService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.dao.CannotAcquireLockException;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.CannotCreateTransactionException;

import javax.sql.DataSource;
import java.sql.SQLException;

import static org.hamcrest.Matchers.not;
import static org.hamcrest.Matchers.containsString;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Failure paths that are hard to trigger against a real database: outages, lock timeouts
 * and unexpected errors must map to the documented status codes without leaking internals.
 */
@WebMvcTest(controllers = {HealthController.class, ProductController.class})
@Import(GlobalExceptionHandler.class)
class FailurePathWebTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private DataSource dataSource;

    @MockitoBean
    private ProductService productService;

    @Test
    void readinessReportsDownWith503WhenDatabaseIsUnreachable() throws Exception {
        when(dataSource.getConnection()).thenThrow(new SQLException("Communications link failure"));

        mockMvc.perform(get("/api/health/ready"))
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.status").value("DOWN"))
                .andExpect(jsonPath("$.database").value("DOWN"));

        // Liveness must stay UP so Kubernetes does not restart pods during a DB outage
        mockMvc.perform(get("/api/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @Test
    void databaseOutageMapsTo503WithGenericMessage() throws Exception {
        when(productService.getAllProducts())
                .thenThrow(new CannotCreateTransactionException("Could not open JPA EntityManager: jdbc://secret-host"));

        mockMvc.perform(get("/api/products"))
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.message").value(containsString("temporarily unavailable")))
                .andExpect(jsonPath("$.message").value(not(containsString("secret-host"))));
    }

    @Test
    void lockTimeoutMapsTo409Retry() throws Exception {
        org.mockito.Mockito.doThrow(new CannotAcquireLockException("Lock wait timeout exceeded"))
                .when(productService).deleteProduct(any());

        mockMvc.perform(delete("/api/products/1"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.message").value(containsString("retry")));
    }

    @Test
    void unexpectedErrorsReturn500WithoutInternalDetails() throws Exception {
        when(productService.getProductById(any()))
                .thenThrow(new IllegalStateException("NullPointer in com.example.internal.Secret"));

        mockMvc.perform(get("/api/products/1"))
                .andExpect(status().isInternalServerError())
                .andExpect(jsonPath("$.message").value("An unexpected server error occurred"));
    }
}
