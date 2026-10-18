package com.example.orderinventory.service;

import com.example.orderinventory.dto.*;
import com.example.orderinventory.entity.Order;
import com.example.orderinventory.entity.OrderItem;
import com.example.orderinventory.entity.OrderStatus;
import com.example.orderinventory.entity.Product;
import com.example.orderinventory.entity.User;
import com.example.orderinventory.exception.BadRequestException;
import com.example.orderinventory.exception.ResourceNotFoundException;
import com.example.orderinventory.repository.OrderRepository;
import com.example.orderinventory.repository.ProductRepository;
import com.example.orderinventory.repository.UserRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

@Service
@Transactional
public class OrderService {

    private static final Logger log = LoggerFactory.getLogger(OrderService.class);

    private final OrderRepository orderRepository;
    private final UserRepository userRepository;
    private final ProductRepository productRepository;

    public OrderService(OrderRepository orderRepository,
                        UserRepository userRepository,
                        ProductRepository productRepository) {
        this.orderRepository = orderRepository;
        this.userRepository = userRepository;
        this.productRepository = productRepository;
    }

    @Transactional(readOnly = true)
    public List<OrderResponse> getAllOrders() {
        return orderRepository.findAllByOrderByCreatedAtDesc().stream()
                .map(this::mapToResponse)
                .collect(Collectors.toList());
    }

    @Transactional(readOnly = true)
    public OrderResponse getOrderById(Long id) {
        Order order = orderRepository.findById(id)
                .orElseThrow(() -> new ResourceNotFoundException("Order not found with id: " + id));
        return mapToResponse(order);
    }

    public OrderResponse createOrder(OrderRequest request) {
        User user = userRepository.findById(request.getUserId())
                .orElseThrow(() -> new ResourceNotFoundException("User not found with id: " + request.getUserId()));

        if (request.getItems() == null || request.getItems().isEmpty()) {
            throw new BadRequestException("Order must contain at least one item");
        }

        // Lock every product row up front, in ascending id order, so concurrent orders
        // serialize on stock and cannot deadlock against each other.
        Map<Long, Product> lockedProducts = new HashMap<>();
        request.getItems().stream()
                .map(OrderItemRequest::getProductId)
                .distinct()
                .sorted()
                .forEach(productId -> lockedProducts.put(productId, productRepository.findByIdForUpdate(productId)
                        .orElseThrow(() -> new ResourceNotFoundException("Product not found with id: " + productId))));

        Order order = new Order();
        order.setUser(user);
        order.setStatus(OrderStatus.PENDING);

        BigDecimal totalAmount = BigDecimal.ZERO;
        List<OrderItem> orderItems = new ArrayList<>();

        for (OrderItemRequest itemReq : request.getItems()) {
            Product product = lockedProducts.get(itemReq.getProductId());

            if (product.getStockQuantity() < itemReq.getQuantity()) {
                log.warn("Order rejected for user {}: insufficient stock for product {} (available {}, requested {})",
                        user.getId(), product.getId(), product.getStockQuantity(), itemReq.getQuantity());
                throw new BadRequestException("Insufficient stock for product '" + product.getName() +
                        "'. Available: " + product.getStockQuantity() + ", Requested: " + itemReq.getQuantity());
            }

            // Deduct stock
            product.setStockQuantity(product.getStockQuantity() - itemReq.getQuantity());
            productRepository.save(product);

            OrderItem orderItem = new OrderItem();
            orderItem.setOrder(order);
            orderItem.setProduct(product);
            orderItem.setQuantity(itemReq.getQuantity());
            orderItem.setPrice(product.getPrice());

            orderItems.add(orderItem);

            BigDecimal lineTotal = product.getPrice().multiply(BigDecimal.valueOf(itemReq.getQuantity()));
            totalAmount = totalAmount.add(lineTotal);
        }

        order.setTotalAmount(totalAmount);
        order.setItems(orderItems);

        Order savedOrder = orderRepository.save(order);
        log.info("Order {} created for user {}: {} line(s), total {}",
                savedOrder.getId(), user.getId(), orderItems.size(), totalAmount);
        return mapToResponse(savedOrder);
    }

    public OrderResponse updateOrderStatus(Long id, OrderStatusUpdateRequest request) {
        Order order = orderRepository.findByIdForUpdate(id)
                .orElseThrow(() -> new ResourceNotFoundException("Order not found with id: " + id));

        OrderStatus currentStatus = order.getStatus();
        OrderStatus newStatus = request.getStatus();

        // Cancelling returns stock to inventory; re-opening would require re-reserving it,
        // so a cancelled order is final.
        if (currentStatus == OrderStatus.CANCELLED && newStatus != OrderStatus.CANCELLED) {
            log.warn("Order {} status change rejected: {} -> {} (cancelled orders are final)", id, currentStatus, newStatus);
            throw new BadRequestException("Order " + id + " is cancelled and cannot be moved to " + newStatus);
        }

        // If transitioning to CANCELLED from another status, restore inventory stock
        if (newStatus == OrderStatus.CANCELLED && currentStatus != OrderStatus.CANCELLED) {
            order.getItems().stream()
                    .sorted(Comparator.comparing(item -> item.getProduct().getId()))
                    .forEach(item -> {
                        Product product = productRepository.findByIdForUpdate(item.getProduct().getId())
                                .orElseThrow(() -> new ResourceNotFoundException("Product not found with id: " + item.getProduct().getId()));
                        product.setStockQuantity(product.getStockQuantity() + item.getQuantity());
                        productRepository.save(product);
                    });
        }

        if (newStatus == OrderStatus.CANCELLED && currentStatus != OrderStatus.CANCELLED) {
            log.info("Order {} cancelled: stock restored for {} line(s)", id, order.getItems().size());
        }
        log.info("Order {} status {} -> {}", id, currentStatus, newStatus);
        order.setStatus(newStatus);
        Order updatedOrder = orderRepository.save(order);
        return mapToResponse(updatedOrder);
    }

    private OrderResponse mapToResponse(Order order) {
        List<OrderItemResponse> itemResponses = order.getItems().stream()
                .map(item -> new OrderItemResponse(
                        item.getId(),
                        item.getProduct().getId(),
                        item.getProduct().getName(),
                        item.getProduct().getCategory(),
                        item.getQuantity(),
                        item.getPrice(),
                        item.getPrice().multiply(BigDecimal.valueOf(item.getQuantity()))
                ))
                .collect(Collectors.toList());

        return new OrderResponse(
                order.getId(),
                order.getUser().getId(),
                order.getUser().getName(),
                order.getUser().getEmail(),
                order.getTotalAmount(),
                order.getStatus(),
                order.getCreatedAt(),
                itemResponses
        );
    }
}
