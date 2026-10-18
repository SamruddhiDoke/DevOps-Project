# Order & Inventory Management System — Application

A **Order & Inventory Management System** built with **Spring Boot 4**, **React (Vite)**, and **MySQL**.
This is the application deployed by the DevOps platform described in the [root README](../README.md)
(Docker, Terraform, EKS, Jenkins, monitoring).

---

## 📁 Structure

```text
order-inventory-platform/
├── frontend/                     # React + Vite frontend application
│   ├── nginx/                    # Production nginx config (SPA fallback + /api reverse proxy)
│   ├── src/
│   │   ├── components/           # Reusable UI components (Sidebar, Header, StatCard, StatusBadge, Modal, Toast)
│   │   ├── pages/                # Application pages (Dashboard, Products, Orders, Users, Login)
│   │   ├── services/             # Centralized API service (Fetch API) + tests
│   │   ├── test/                 # Vitest setup and helpers
│   │   ├── App.jsx               # React Router navigation (+ App.test.jsx)
│   │   ├── index.css             # Enterprise design system CSS
│   │   └── main.jsx
│   ├── Dockerfile                # node:24 build → nginx-unprivileged runtime
│   ├── package.json
│   └── vite.config.js            # Dev proxy for /api + Vitest config
│
├── backend/                      # Spring Boot Java backend application
│   ├── src/main/java/com/example/orderinventory/
│   │   ├── config/               # CORS configuration
│   │   ├── controller/           # REST Controllers (Health, Users, Products, Orders)
│   │   ├── dto/                  # Data Transfer Objects & Validation rules
│   │   ├── entity/               # JPA Entities (User, Product, Order, OrderItem, OrderStatus)
│   │   ├── exception/            # Global Exception Handler & Custom Errors
│   │   ├── repository/           # Spring Data JPA Repositories (incl. row-locking queries)
│   │   └── service/              # Business Logic Services
│   ├── src/main/resources/application.properties
│   ├── src/test/                 # API integration + concurrency tests (H2)
│   ├── Dockerfile                # Maven build → JRE runtime (non-root)
│   └── pom.xml
│
├── database/                     # MySQL scripts (run automatically on the first Docker Compose start)
│   ├── schema.sql                # Tables, foreign keys and indexes
│   ├── data.sql                  # Demo seed data
│   └── README.md
│
├── logging/                      # Filebeat + ILM policy for the ELK overlay
├── docker-compose.yml            # MySQL + backend + frontend
├── docker-compose.logging.yml    # Optional Elasticsearch/Kibana/Filebeat
└── .env.example
```

---

## 🚀 Quick start (Docker Compose)

```bash
cp .env.example .env              # optional
docker compose up -d --build
# UI:  http://localhost:3000      API: http://localhost:8080/api/health
```

The first start creates the schema and demo data in a persistent volume. See the root README for
ports, the ELK overlay and troubleshooting.

---

## ☕ Backend (Spring Boot)

### Prerequisites
- Java 17+ and Maven 3.9+
- MySQL 8 — the default configuration targets the Compose MySQL on `localhost:3307`
  (`docker compose up -d mysql`)

### Configuration
All settings in `backend/src/main/resources/application.properties` can be overridden with environment
variables — do not edit credentials into the file:

```bash
export SPRING_DATASOURCE_URL='jdbc:mysql://localhost:3307/order_inventory_db?useSSL=false&serverTimezone=UTC&allowPublicKeyRetrieval=true'
export SPRING_DATASOURCE_USERNAME=inventory
export SPRING_DATASOURCE_PASSWORD='<password>'
```

Hibernate creates/updates the tables on startup (`spring.jpa.hibernate.ddl-auto=update`).

### Run & test
```bash
cd backend
mvn spring-boot:run      # http://localhost:8080
mvn clean test           # 14 tests, in-memory H2 database (no MySQL needed)
```

---

## ⚛️ Frontend (React + Vite)

### Prerequisites
- Node.js ≥ 20.19 and npm

### Run & test
```bash
cd frontend
npm install
npm run dev     # http://localhost:5173 — /api is proxied to http://localhost:8080
npm test        # 12 tests (Vitest + Testing Library)
npm run build   # production bundle in dist/
```

### API configuration
The app calls the same-origin path `/api`. In production nginx (Docker Compose) or the ALB Ingress (EKS)
routes it to the backend; in development the Vite proxy does (override the target with
`VITE_DEV_API_PROXY`). To call a different API location, build with `VITE_API_BASE_URL`:
```bash
VITE_API_BASE_URL=https://api.example.com/api npm run build
```

---

## 🔌 REST API Endpoints

### 🩺 Health Check
| Method | Endpoint | Description | Response |
| :--- | :--- | :--- | :--- |
| `GET` | `/api/health` | Liveness: service is up (no DB check) | `{"status": "UP"}` |
| `GET` | `/api/health/ready` | Readiness: database reachable | `{"status":"UP","database":"UP"}` or **503** |

### 👥 Users API
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/users` | List all users |
| `GET` | `/api/users/{id}` | Get user details by ID |
| `POST` | `/api/users` | Create a new user (email is stored lower-case and must be unique) |

### 📦 Products API
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/products` | List all products with stock status |
| `GET` | `/api/products/{id}` | Get product details by ID |
| `POST` | `/api/products` | Create a new product |
| `PUT` | `/api/products/{id}` | Update product details and stock |
| `DELETE` | `/api/products/{id}` | Delete product (**409** if it appears in any order) |

### 🛒 Orders API
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/orders` | List all orders with line items |
| `GET` | `/api/orders/{id}` | Get order details by ID |
| `POST` | `/api/orders` | Create multi-item order (atomically reserves stock; concurrent orders cannot oversell) |
| `PUT` | `/api/orders/{id}/status` | Update order status (`PENDING`, `CONFIRMED`, `SHIPPED`, `DELIVERED`, `CANCELLED`). Cancelling returns stock to inventory; a cancelled order is final. |

### ⚠️ Error responses
Errors use one JSON shape: `{"timestamp","status","error","message","details","path"}`.

| Status | When |
|---|---|
| 400 | Validation failure (`details` lists field errors), malformed JSON, unknown enum value, non-numeric id, insufficient stock, invalid status transition, duplicate email |
| 404 | Unknown resource id or API route |
| 405 | HTTP method not supported for the route |
| 409 | Conflicting data (e.g. deleting a product referenced by orders) or concurrent update lock timeout |
| 503 | Database temporarily unavailable |
| 500 | Unexpected error (details are logged server-side, never returned) |
