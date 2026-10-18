-- Demo data for local environments only (enabled by adding classpath:db/seed to
-- SPRING_FLYWAY_LOCATIONS, as docker-compose.yml does). Never enabled on AWS.
-- Inserts nothing unless the users table is empty, so it never touches real data.
-- (Columns of the first SELECT in each block are aliased: MySQL rejects duplicate column
-- names such as "1, 1" in a derived table.)

SET @seed_demo_data = (SELECT COUNT(*) = 0 FROM users);

INSERT INTO users (id, name, email, phone, created_at)
SELECT * FROM (
  SELECT 1 AS id, 'Alex Morgan' AS name, 'alex.morgan@example.com' AS email, '+1-555-0101' AS phone, TIMESTAMP('2026-09-01 10:00:00') AS created_at UNION ALL
  SELECT 2, 'Sarah Connor', 'sarah.connor@example.com', '+1-555-0102', TIMESTAMP('2026-09-05 11:30:00') UNION ALL
  SELECT 3, 'David Miller', 'david.miller@example.com', '+1-555-0103', TIMESTAMP('2026-09-12 14:15:00') UNION ALL
  SELECT 4, 'Elena Rostova', 'elena.rostova@example.com', '+1-555-0104', TIMESTAMP('2026-09-18 09:45:00') UNION ALL
  SELECT 5, 'Marcus Vance', 'marcus.vance@example.com', '+1-555-0105', TIMESTAMP('2026-09-25 16:20:00')
) AS seed WHERE @seed_demo_data;

INSERT INTO products (id, name, description, price, stock_quantity, category, created_at)
SELECT * FROM (
  SELECT 1 AS id, 'ProBook 15 Gen 4 Laptop' AS name, '15.6 inch FHD, Intel i7, 16GB RAM, 512GB SSD enterprise laptop' AS description, 1199.99 AS price, 25 AS stock_quantity, 'Electronics' AS category, TIMESTAMP('2026-09-01 08:00:00') AS created_at UNION ALL
  SELECT 2, 'Wireless Ergonomic Mouse', '2.4GHz multi-device ergonomic mouse with silent clicks', 49.99, 4, 'Accessories', TIMESTAMP('2026-09-01 08:30:00') UNION ALL
  SELECT 3, 'Mechanical RGB Keyboard', 'Tactile switch mechanical keyboard with aluminum frame', 89.99, 18, 'Accessories', TIMESTAMP('2026-09-02 09:00:00') UNION ALL
  SELECT 4, 'UltraSharp 27" 4K Monitor', '27-inch IPS UHD 4K HDR monitor with USB-C hub', 449.99, 2, 'Monitors', TIMESTAMP('2026-09-02 10:00:00') UNION ALL
  SELECT 5, 'Noise-Cancelling Headset', 'Over-ear active noise cancelling headset with studio mic', 179.99, 0, 'Audio', TIMESTAMP('2026-09-03 11:00:00') UNION ALL
  SELECT 6, 'Thunderbolt 4 Docking Station', 'Dual 4K display output with 96W power delivery', 199.99, 15, 'Accessories', TIMESTAMP('2026-09-04 12:00:00') UNION ALL
  SELECT 7, 'Ergonomic Mesh Office Chair', 'High back breathable mesh chair with adjustable lumbar support', 289.99, 8, 'Furniture', TIMESTAMP('2026-09-05 13:00:00') UNION ALL
  SELECT 8, '4K Ultra HD Streaming Webcam', 'Autofocus webcam with privacy shutter and stereo microphones', 79.99, 30, 'Electronics', TIMESTAMP('2026-09-06 14:00:00')
) AS seed WHERE @seed_demo_data;

INSERT INTO orders (id, user_id, total_amount, status, created_at)
SELECT * FROM (
  SELECT 1 AS id, 1 AS user_id, 1249.98 AS total_amount, 'DELIVERED' AS status, TIMESTAMP('2026-09-28 10:15:00') AS created_at UNION ALL
  SELECT 2, 2, 449.99, 'SHIPPED', TIMESTAMP('2026-10-01 14:20:00') UNION ALL
  SELECT 3, 3, 269.98, 'CONFIRMED', TIMESTAMP('2026-10-02 16:45:00') UNION ALL
  SELECT 4, 4, 1199.99, 'PENDING', TIMESTAMP('2026-10-03 11:10:00') UNION ALL
  SELECT 5, 5, 89.99, 'CANCELLED', TIMESTAMP('2026-10-03 15:30:00')
) AS seed WHERE @seed_demo_data;

INSERT INTO order_items (id, order_id, product_id, quantity, price)
SELECT * FROM (
  SELECT 1 AS id, 1 AS order_id, 1 AS product_id, 1 AS quantity, 1199.99 AS price UNION ALL
  SELECT 2, 1, 2, 1, 49.99 UNION ALL
  SELECT 3, 2, 4, 1, 449.99 UNION ALL
  SELECT 4, 3, 3, 1, 89.99 UNION ALL
  SELECT 5, 3, 5, 1, 179.99 UNION ALL
  SELECT 6, 4, 1, 1, 1199.99 UNION ALL
  SELECT 7, 5, 3, 1, 89.99
) AS seed WHERE @seed_demo_data;
