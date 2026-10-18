# Database Setup: Order & Inventory Management System

This directory contains the database definition and initial seed data for the **Order & Inventory Management System**.

## Database Details

- **Database Name**: `order_inventory_db`
- **Engine**: MySQL 8.x / MariaDB
- **Character Set**: `utf8mb4`

## Files

1. **`schema.sql`**: Creates the `order_inventory_db` database and defined tables (`users`, `products`, `orders`, `order_items`) along with foreign key constraints and indexes.
2. **`data.sql`**: Seeds realistic mock data for users, products (with varying stock quantities including low-stock and out-of-stock items), and multi-item orders across different statuses.

## Quick Setup Instructions

> **Docker Compose runs both scripts automatically** the first time the MySQL volume is created
> (`docker compose up`); no manual step is needed. On EKS/RDS the backend creates the tables on
> startup (Hibernate `ddl-auto=update`).
>
> ⚠️ `schema.sql` starts with `DROP TABLE` statements. Running it manually against an existing
> database **deletes all data** — only use it on an empty or disposable database.

### Option 1: MySQL CLI
```bash
# 1. Run schema creation
mysql -u root -p < schema.sql

# 2. Populate sample data
mysql -u root -p < data.sql
```

### Option 2: MySQL Workbench / DBeaver / phpMyAdmin
1. Open and execute `schema.sql`
2. Open and execute `data.sql`

## Database Entity Relationships

- `users` (1) ─── (N) `orders`
- `orders` (1) ─── (N) `order_items`
- `products` (1) ─── (N) `order_items`
