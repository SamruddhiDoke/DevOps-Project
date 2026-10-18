-- Baseline schema: matches the tables the application (JPA entities) has always used.
-- Existing databases created before Flyway was introduced are baselined at version 1
-- (spring.flyway.baseline-on-migrate), so this script only runs on empty databases.

CREATE TABLE users (
    id         BIGINT       NOT NULL AUTO_INCREMENT,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(100) NOT NULL,
    phone      VARCHAR(20),
    created_at DATETIME(6)  NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uk_users_email UNIQUE (email)
);

CREATE TABLE products (
    id             BIGINT        NOT NULL AUTO_INCREMENT,
    name           VARCHAR(150)  NOT NULL,
    description    TEXT,
    price          DECIMAL(10,2) NOT NULL,
    stock_quantity INT           NOT NULL,
    category       VARCHAR(50),
    created_at     DATETIME(6)   NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE orders (
    id           BIGINT        NOT NULL AUTO_INCREMENT,
    user_id      BIGINT        NOT NULL,
    total_amount DECIMAL(10,2) NOT NULL,
    status       ENUM('CANCELLED','CONFIRMED','DELIVERED','PENDING','SHIPPED') NOT NULL,
    created_at   DATETIME(6)   NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_orders_user FOREIGN KEY (user_id) REFERENCES users (id)
);

CREATE TABLE order_items (
    id         BIGINT        NOT NULL AUTO_INCREMENT,
    order_id   BIGINT        NOT NULL,
    product_id BIGINT        NOT NULL,
    quantity   INT           NOT NULL,
    price      DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_order_items_order   FOREIGN KEY (order_id)   REFERENCES orders (id),
    CONSTRAINT fk_order_items_product FOREIGN KEY (product_id) REFERENCES products (id)
);
