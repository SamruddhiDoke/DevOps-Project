package com.example.orderinventory.repository;

import com.example.orderinventory.entity.Product;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface ProductRepository extends JpaRepository<Product, Long> {
    List<Product> findByStockQuantityLessThanEqual(Integer threshold);
    List<Product> findByCategoryIgnoreCase(String category);
}
