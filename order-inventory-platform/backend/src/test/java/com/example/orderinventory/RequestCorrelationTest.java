package com.example.orderinventory;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Request ids let an operator find every log line of a failed request (see docs/RUNBOOKS.md). */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class RequestCorrelationTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void generatesRequestIdWhenNoneIsSupplied() throws Exception {
        MvcResult result = mockMvc.perform(get("/api/health"))
                .andExpect(status().isOk())
                .andReturn();
        assertThat(result.getResponse().getHeader("X-Request-Id"))
                .matches("[0-9a-f-]{36}");
    }

    @Test
    void propagatesIncomingRequestIdToResponseAndErrorBody() throws Exception {
        mockMvc.perform(get("/api/orders/999999").header("X-Request-Id", "nginx-abc123"))
                .andExpect(status().isNotFound())
                .andExpect(header().string("X-Request-Id", "nginx-abc123"))
                .andExpect(jsonPath("$.requestId").value("nginx-abc123"));
    }

    @Test
    void replacesUnsafeIncomingRequestIds() throws Exception {
        MvcResult result = mockMvc.perform(get("/api/health").header("X-Request-Id", "bad id\nINJECTED log line"))
                .andExpect(status().isOk())
                .andReturn();
        assertThat(result.getResponse().getHeader("X-Request-Id"))
                .doesNotContain("INJECTED")
                .matches("[0-9a-f-]{36}");
    }
}
