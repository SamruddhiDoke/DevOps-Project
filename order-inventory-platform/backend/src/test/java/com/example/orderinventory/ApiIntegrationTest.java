package com.example.orderinventory;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.hasItem;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * End-to-end API tests through the full Spring stack (MVC, validation, services, JPA, transactions)
 * against an isolated in-memory database.
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class ApiIntegrationTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @BeforeEach
    void cleanDatabase() {
        jdbcTemplate.update("DELETE FROM order_items");
        jdbcTemplate.update("DELETE FROM orders");
        jdbcTemplate.update("DELETE FROM products");
        jdbcTemplate.update("DELETE FROM users");
    }

    // ------------------------------------------------------------------ helpers

    private JsonNode postJson(String url, String body, int expectedStatus) throws Exception {
        MvcResult result = mockMvc.perform(post(url).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().is(expectedStatus))
                .andReturn();
        String content = result.getResponse().getContentAsString();
        return content.isEmpty() ? null : objectMapper.readTree(content);
    }

    private long createUser(String email) throws Exception {
        return postJson("/api/users",
                "{\"name\":\"Test User\",\"email\":\"" + email + "\",\"phone\":\"+1-555-0100\"}", 201)
                .get("id").asLong();
    }

    private long createProduct(String name, String price, int stock) throws Exception {
        return postJson("/api/products",
                "{\"name\":\"" + name + "\",\"price\":" + price + ",\"stockQuantity\":" + stock + ",\"category\":\"Test\"}", 201)
                .get("id").asLong();
    }

    private JsonNode createOrder(long userId, long productId, int quantity, int expectedStatus) throws Exception {
        return postJson("/api/orders",
                "{\"userId\":" + userId + ",\"items\":[{\"productId\":" + productId + ",\"quantity\":" + quantity + "}]}",
                expectedStatus);
    }

    private int stockOf(long productId) throws Exception {
        MvcResult result = mockMvc.perform(get("/api/products/" + productId)).andExpect(status().isOk()).andReturn();
        return objectMapper.readTree(result.getResponse().getContentAsString()).get("stockQuantity").asInt();
    }

    private void updateStatus(long orderId, String newStatus, int expectedStatus) throws Exception {
        mockMvc.perform(put("/api/orders/" + orderId + "/status")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"status\":\"" + newStatus + "\"}"))
                .andExpect(status().is(expectedStatus));
    }

    // ------------------------------------------------------------------ health

    @Test
    void healthEndpointsReportUp() throws Exception {
        mockMvc.perform(get("/api/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"))
                .andExpect(jsonPath("$.database").doesNotExist());

        mockMvc.perform(get("/api/health/ready"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"))
                .andExpect(jsonPath("$.database").value("UP"));
    }

    // ------------------------------------------------------------------ users

    @Test
    void createsAndFetchesUsers() throws Exception {
        long id = createUser("Jane.Doe@Example.com");

        mockMvc.perform(get("/api/users/" + id))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.email").value("jane.doe@example.com"))
                .andExpect(jsonPath("$.createdAt").exists());

        mockMvc.perform(get("/api/users"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[*].id", hasItem((int) id)));
    }

    @Test
    void rejectsDuplicateEmailCaseInsensitively() throws Exception {
        createUser("dup@example.com");

        JsonNode error = postJson("/api/users", "{\"name\":\"Other\",\"email\":\"DUP@example.com\"}", 400);
        assertThat(error.get("message").asString()).contains("already registered");
    }

    @Test
    void validatesUserInput() throws Exception {
        JsonNode error = postJson("/api/users", "{\"name\":\"\",\"email\":\"not-an-email\"}", 400);
        assertThat(error.get("error").asString()).isEqualTo("Validation Failed");
        assertThat(error.get("details").toString()).contains("name", "email");
    }

    // ------------------------------------------------------------------ products

    @Test
    void productCrudLifecycleWithStockStatus() throws Exception {
        long id = createProduct("Widget", "9.99", 5);

        mockMvc.perform(get("/api/products/" + id))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("LOW_STOCK"));

        mockMvc.perform(put("/api/products/" + id)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"Widget Pro\",\"price\":19.99,\"stockQuantity\":50,\"category\":\"Tools\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.name").value("Widget Pro"))
                .andExpect(jsonPath("$.status").value("IN_STOCK"));

        mockMvc.perform(delete("/api/products/" + id)).andExpect(status().isNoContent());
        mockMvc.perform(get("/api/products/" + id)).andExpect(status().isNotFound());
        mockMvc.perform(delete("/api/products/" + id)).andExpect(status().isNotFound());
    }

    @Test
    void validatesProductInput() throws Exception {
        JsonNode error = postJson("/api/products", "{\"name\":\"X\",\"price\":0,\"stockQuantity\":-1}", 400);
        assertThat(error.get("details").toString()).contains("price", "stockQuantity");
    }

    @Test
    void deletingProductReferencedByOrdersReturnsConflict() throws Exception {
        long userId = createUser("buyer@example.com");
        long productId = createProduct("Referenced", "5.00", 10);
        createOrder(userId, productId, 1, 201);

        mockMvc.perform(delete("/api/products/" + productId))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.message").value(containsString("referenced by existing orders")));

        assertThat(stockOf(productId)).isEqualTo(9);
    }

    // ------------------------------------------------------------------ orders

    @Test
    void creatingOrderDeductsStockAndComputesTotal() throws Exception {
        long userId = createUser("order@example.com");
        long productId = createProduct("Keyboard", "89.99", 10);

        JsonNode order = createOrder(userId, productId, 3, 201);

        assertThat(order.get("status").asString()).isEqualTo("PENDING");
        assertThat(order.get("totalAmount").decimalValue()).isEqualByComparingTo("269.97");
        assertThat(order.get("items").get(0).get("subtotal").decimalValue()).isEqualByComparingTo("269.97");
        assertThat(stockOf(productId)).isEqualTo(7);

        mockMvc.perform(get("/api/orders/" + order.get("id").asLong()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.userEmail").value("order@example.com"));
    }

    @Test
    void rejectsOrderExceedingStockWithoutChangingInventory() throws Exception {
        long userId = createUser("greedy@example.com");
        long productId = createProduct("Scarce", "10.00", 2);

        JsonNode error = createOrder(userId, productId, 3, 400);

        assertThat(error.get("message").asString()).contains("Insufficient stock");
        assertThat(stockOf(productId)).isEqualTo(2);
    }

    @Test
    void duplicateLinesForSameProductAreCheckedAgainstCombinedStock() throws Exception {
        long userId = createUser("lines@example.com");
        long productId = createProduct("Pair", "1.00", 3);

        postJson("/api/orders",
                "{\"userId\":" + userId + ",\"items\":[{\"productId\":" + productId + ",\"quantity\":2},"
                        + "{\"productId\":" + productId + ",\"quantity\":2}]}", 400);

        assertThat(stockOf(productId)).isEqualTo(3);
    }

    @Test
    void rejectsOrdersForUnknownUserOrProduct() throws Exception {
        long userId = createUser("known@example.com");
        long productId = createProduct("Known", "1.00", 1);

        createOrder(999_999L, productId, 1, 404);
        createOrder(userId, 999_999L, 1, 404);
        postJson("/api/orders", "{\"userId\":" + userId + ",\"items\":[]}", 400);
    }

    @Test
    void cancellingRestoresStockOnceAndCancelledOrdersAreFinal() throws Exception {
        long userId = createUser("cancel@example.com");
        long productId = createProduct("Returnable", "20.00", 10);
        long orderId = createOrder(userId, productId, 4, 201).get("id").asLong();
        assertThat(stockOf(productId)).isEqualTo(6);

        updateStatus(orderId, "CONFIRMED", 200);
        updateStatus(orderId, "CANCELLED", 200);
        assertThat(stockOf(productId)).isEqualTo(10);

        // Repeating the cancellation must not restock twice
        updateStatus(orderId, "CANCELLED", 200);
        assertThat(stockOf(productId)).isEqualTo(10);

        // Re-opening would sell stock that was already returned
        updateStatus(orderId, "PENDING", 400);
        assertThat(stockOf(productId)).isEqualTo(10);
    }

    // ------------------------------------------------------------------ error handling

    @Test
    void malformedAndInvalidRequestsReturnClientErrorsNotServerErrors() throws Exception {
        long userId = createUser("errors@example.com");
        long productId = createProduct("Thing", "1.00", 1);
        long orderId = createOrder(userId, productId, 1, 201).get("id").asLong();

        // Malformed JSON
        mockMvc.perform(post("/api/products").contentType(MediaType.APPLICATION_JSON).content("{\"name\":"))
                .andExpect(status().isBadRequest());

        // Unknown enum value
        mockMvc.perform(put("/api/orders/" + orderId + "/status")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"status\":\"LOST\"}"))
                .andExpect(status().isBadRequest());

        // Non-numeric id
        mockMvc.perform(get("/api/products/abc")).andExpect(status().isBadRequest());

        // Unknown route and unsupported method
        mockMvc.perform(get("/api/does-not-exist")).andExpect(status().isNotFound());
        mockMvc.perform(delete("/api/users/" + userId)).andExpect(status().isMethodNotAllowed());

        // Missing resources
        mockMvc.perform(get("/api/orders/999999")).andExpect(status().isNotFound());
        updateStatus(999_999L, "SHIPPED", 404);
    }
}
