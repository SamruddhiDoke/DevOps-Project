# Database: Order & Inventory Management System

- **Engine:** MySQL 8.4 (Docker Compose locally, Amazon RDS on AWS)
- **Database:** `order_inventory_db` (utf8mb4)
- **Schema owner:** Flyway — migrations live in
  `backend/src/main/resources/db/migration` and run automatically when the backend starts.
  Hibernate only validates that the entities match (`ddl-auto=validate`).

| Migration | Content |
|---|---|
| `V1__initial_schema.sql` | `users`, `products`, `orders`, `order_items` with primary/foreign keys and the unique email |
| `V2__indexes_and_integrity_checks.sql` | indexes on order status/date and product category; `CHECK` constraints: stock ≥ 0, price > 0, quantity > 0 |
| `db/seed/R__demo_data.sql` | demo users/products/orders — **local only** (enabled in `docker-compose.yml`) and inserted **only when `users` is empty** |

Relationships: `users 1─N orders`, `orders 1─N order_items`, `products 1─N order_items`.

## Existing databases

A database created before Flyway was adopted (tables already present, no `flyway_schema_history`) is
**baselined at version 1**: nothing in it is changed or deleted; `V2` and later migrations then apply.
Back up first anyway:

```powershell
docker exec inventory-mysql sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --databases order_inventory_db' > backup.sql
```

## Adding a schema change

Create `V3__short_description.sql` (never edit an applied migration), keep it backward compatible for one
release (rollbacks run the previous app version on the new schema), run `mvn verify` (tests apply all
migrations to an in-memory database and validate the entities), then start the stack.

The former `schema.sql` / `data.sql` scripts were replaced by these migrations (their first statements
dropped all tables, which made them unsafe to re-run).
