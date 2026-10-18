-- Query-path indexes and database-level guards for invariants the API already enforces.
-- Runs on new databases and on databases baselined at version 1 (existing data satisfies
-- these rules because the API validates them).

CREATE INDEX idx_orders_status     ON orders (status);
CREATE INDEX idx_orders_created_at ON orders (created_at);
CREATE INDEX idx_products_category ON products (category);

ALTER TABLE products    ADD CONSTRAINT chk_products_stock_non_negative CHECK (stock_quantity >= 0);
ALTER TABLE products    ADD CONSTRAINT chk_products_price_positive     CHECK (price > 0);
ALTER TABLE order_items ADD CONSTRAINT chk_order_items_quantity        CHECK (quantity > 0);
