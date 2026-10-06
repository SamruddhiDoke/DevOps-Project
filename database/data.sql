-- ==========================================================
-- Sample Seed Data for Order & Inventory Management System
-- ==========================================================

USE order_inventory_db;

-- ----------------------------------------------------------
-- 1. Insert Sample Users
-- ----------------------------------------------------------
INSERT INTO users (id, name, email, phone, created_at) VALUES
(1, 'Alex Morgan', 'alex.morgan@example.com', '+1-555-0101', '2026-09-01 10:00:00'),
(2, 'Sarah Connor', 'sarah.connor@example.com', '+1-555-0102', '2026-09-05 11:30:00'),
(3, 'David Miller', 'david.miller@example.com', '+1-555-0103', '2026-09-12 14:15:00'),
(4, 'Elena Rostova', 'elena.rostova@example.com', '+1-555-0104', '2026-09-18 09:45:00'),
(5, 'Marcus Vance', 'marcus.vance@example.com', '+1-555-0105', '2026-09-25 16:20:00');

-- ----------------------------------------------------------
-- 2. Insert Sample Products
-- ----------------------------------------------------------
INSERT INTO products (id, name, description, price, stock_quantity, category, created_at) VALUES
(1, 'ProBook 15 Gen 4 Laptop', '15.6 inch FHD, Intel i7, 16GB RAM, 512GB SSD enterprise laptop', 1199.99, 25, 'Electronics', '2026-09-01 08:00:00'),
(2, 'Wireless Ergonomic Mouse', '2.4GHz multi-device ergonomic mouse with silent clicks', 49.99, 4, 'Accessories', '2026-09-01 08:30:00'), -- Low stock
(3, 'Mechanical RGB Keyboard', 'Tactile switch mechanical keyboard with aluminum frame', 89.99, 18, 'Accessories', '2026-09-02 09:00:00'),
(4, 'UltraSharp 27" 4K Monitor', '27-inch IPS UHD 4K HDR monitor with USB-C hub', 449.99, 2, 'Monitors', '2026-09-02 10:00:00'), -- Low stock
(5, 'Noise-Cancelling Headset', 'Over-ear active noise cancelling headset with studio mic', 179.99, 0, 'Audio', '2026-09-03 11:00:00'), -- Out of stock
(6, 'Thunderbolt 4 Docking Station', 'Dual 4K display output with 96W power delivery', 199.99, 15, 'Accessories', '2026-09-04 12:00:00'),
(7, 'Ergonomic Mesh Office Chair', 'High back breathable mesh chair with adjustable lumbar support', 289.99, 8, 'Furniture', '2026-09-05 13:00:00'), -- Low stock
(8, '4K Ultra HD Streaming Webcam', 'Autofocus webcam with privacy shutter and stereo microphones', 79.99, 30, 'Electronics', '2026-09-06 14:00:00');

-- ----------------------------------------------------------
-- 3. Insert Sample Orders
-- ----------------------------------------------------------
INSERT INTO orders (id, user_id, total_amount, status, created_at) VALUES
(1, 1, 1249.98, 'DELIVERED', '2026-09-28 10:15:00'),
(2, 2, 449.99, 'SHIPPED', '2026-10-01 14:20:00'),
(3, 3, 269.98, 'CONFIRMED', '2026-10-02 16:45:00'),
(4, 4, 1199.99, 'PENDING', '2026-10-03 11:10:00'),
(5, 5, 89.99, 'CANCELLED', '2026-10-03 15:30:00');

-- ----------------------------------------------------------
-- 4. Insert Sample Order Items
-- ----------------------------------------------------------
INSERT INTO order_items (id, order_id, product_id, quantity, price) VALUES
-- Order 1: 1x Laptop (1199.99) + 1x Mouse (49.99) = 1249.98
(1, 1, 1, 1, 1199.99),
(2, 1, 2, 1, 49.99),
-- Order 2: 1x 4K Monitor (449.99)
(3, 2, 4, 1, 449.99),
-- Order 3: 1x Keyboard (89.99) + 1x Headset (179.99) = 269.98
(4, 3, 3, 1, 89.99),
(5, 3, 5, 1, 179.99),
-- Order 4: 1x Laptop (1199.99)
(6, 4, 1, 1, 1199.99),
-- Order 5: 1x Keyboard (89.99)
(7, 5, 3, 1, 89.99);

-- Reset AUTO_INCREMENT counters to follow seeded data
ALTER TABLE users AUTO_INCREMENT = 6;
ALTER TABLE products AUTO_INCREMENT = 9;
ALTER TABLE orders AUTO_INCREMENT = 6;
ALTER TABLE order_items AUTO_INCREMENT = 8;
