package com.example.orderinventory;

import com.example.orderinventory.dto.OrderItemRequest;
import com.example.orderinventory.dto.OrderRequest;
import com.example.orderinventory.entity.Product;
import com.example.orderinventory.entity.User;
import com.example.orderinventory.exception.BadRequestException;
import com.example.orderinventory.repository.OrderRepository;
import com.example.orderinventory.repository.ProductRepository;
import com.example.orderinventory.repository.UserRepository;
import com.example.orderinventory.service.OrderService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Verifies that concurrent orders for the last units of a product cannot oversell inventory.
 */
@SpringBootTest
@ActiveProfiles("test")
class OrderConcurrencyTest {

    private static final int BUYERS = 8;
    private static final int STOCK = 3;

    @Autowired
    private OrderService orderService;
    @Autowired
    private ProductRepository productRepository;
    @Autowired
    private UserRepository userRepository;
    @Autowired
    private OrderRepository orderRepository;
    @Autowired
    private JdbcTemplate jdbcTemplate;

    @Test
    void concurrentOrdersNeverOversellStock() throws Exception {
        jdbcTemplate.update("DELETE FROM order_items");
        jdbcTemplate.update("DELETE FROM orders");
        jdbcTemplate.update("DELETE FROM products");
        jdbcTemplate.update("DELETE FROM users");

        User user = new User();
        user.setName("Buyer");
        user.setEmail("race@example.com");
        Long userId = userRepository.save(user).getId();

        Product product = new Product();
        product.setName("Last units");
        product.setPrice(new BigDecimal("10.00"));
        product.setStockQuantity(STOCK);
        Long productId = productRepository.save(product).getId();

        ExecutorService pool = Executors.newFixedThreadPool(BUYERS);
        CountDownLatch start = new CountDownLatch(1);
        List<Future<Boolean>> results = new ArrayList<>();
        for (int i = 0; i < BUYERS; i++) {
            results.add(pool.submit(() -> {
                start.await();
                try {
                    orderService.createOrder(new OrderRequest(userId, List.of(new OrderItemRequest(productId, 1))));
                    return true;
                } catch (BadRequestException insufficientStock) {
                    return false;
                }
            }));
        }
        start.countDown();

        int successes = 0;
        for (Future<Boolean> result : results) {
            if (result.get(30, TimeUnit.SECONDS)) {
                successes++;
            }
        }
        pool.shutdown();

        assertThat(successes).isEqualTo(STOCK);
        assertThat(productRepository.findById(productId).orElseThrow().getStockQuantity()).isZero();
        assertThat(orderRepository.count()).isEqualTo(STOCK);
    }
}
