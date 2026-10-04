package com.example.orderinventory.repository;

import com.example.orderinventory.entity.Order;
import com.example.orderinventory.entity.OrderStatus;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface OrderRepository extends JpaRepository<Order, Long> {
    List<Order> findAllByOrderByCreatedAtDesc();
    List<Order> findByUserId(Long userId);
    List<Order> findByStatus(OrderStatus status);
    long countByStatus(OrderStatus status);
}
