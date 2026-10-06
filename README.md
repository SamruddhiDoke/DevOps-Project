# Order & Inventory Management System (DevOps Phase 1 Base Application)

A modern, production-grade **Order & Inventory Management System** built with **Spring Boot 3**, **React (Vite)**, and **MySQL**.

This project serves as the foundational application for subsequent DevOps implementations (Containerization, CI/CD pipelines, Orchestration, Observability, and Cloud Infrastructure).

---

## 📁 Repository Structure

```text
order-inventory-platform/
│
├── frontend/                     # React + Vite frontend application
│   ├── src/
│   │   ├── components/           # Reusable UI components (Sidebar, Header, StatCard, StatusBadge, Modal, Toast)
│   │   ├── pages/                # Application pages (Dashboard, Products, Orders, Users, Login)
│   │   ├── services/             # Centralized API service (Fetch API)
│   │   ├── App.jsx               # React Router navigation
│   │   ├── index.css             # Enterprise design system CSS
│   │   └── main.jsx
│   ├── index.html
│   ├── package.json
│   └── vite.config.js
│
├── backend/                      # Spring Boot 3 Java backend application
│   ├── src/
│   │   ├── main/
│   │   │   ├── java/com/example/orderinventory/
│   │   │   │   ├── config/       # Web & CORS configuration
│   │   │   │   ├── controller/   # REST Controllers (Health, Users, Products, Orders)
│   │   │   │   ├── dto/          # Data Transfer Objects & Validation rules
│   │   │   │   ├── entity/       # JPA Entities (User, Product, Order, OrderItem, OrderStatus)
│   │   │   │   ├── exception/    # Global Exception Handler & Custom Errors
│   │   │   │   ├── repository/   # Spring Data JPA Repositories
│   │   │   │   ├── service/      # Business Logic Services
│   │   │   │   └── OrderInventoryApplication.java
│   │   │   └── resources/
│   │   │       └── application.properties
│   └── pom.xml
│
└── database/                     # MySQL database scripts
    ├── schema.sql                # Database & table creation script
    ├── data.sql                  # Initial mock and seed data
    └── README.md
```

---

## 🗄 Database Setup (MySQL)

1. Open MySQL terminal or database client (e.g., MySQL Workbench, DBeaver).
2. Execute `schema.sql` to initialize `order_inventory_db` and all relational tables with foreign keys and indexes:
   ```bash
   mysql -u root -p < database/schema.sql
   ```
3. (Optional) Populate seed data with sample users, catalog items, and orders:
   ```bash
   mysql -u root -p < database/data.sql
   ```

---

## ☕ Backend Setup (Spring Boot)

### Prerequisites
- Java 17+ (or Java 21 / 26)
- Maven 3.8+
- MySQL Server running on port 3306

### Configuration
Verify MySQL connection credentials in `backend/src/main/resources/application.properties`:
```properties
spring.datasource.url=jdbc:mysql://localhost:3306/order_inventory_db?useSSL=false&serverTimezone=UTC&allowPublicKeyRetrieval=true
spring.datasource.username=root
spring.datasource.password=root
```

### Run Backend
```bash
cd backend
mvn spring-boot:run
```
The backend starts at `http://localhost:8080`.

---

## ⚛️ Frontend Setup (React + Vite)

### Prerequisites
- Node.js 18+ and npm

### Run Frontend
```bash
cd frontend
npm install
npm run dev
```
The frontend starts at `http://localhost:5173`.

### Environment Configuration
The frontend uses a centralized API configuration in `src/services/api.js`. You can override the backend URL using `VITE_API_BASE_URL`:
```bash
# Example for custom API host (e.g. AWS / Docker / Kubernetes)
VITE_API_BASE_URL=http://localhost:8080/api npm run dev
```

---

## 🔌 REST API Endpoints

### 🩺 Health Check
| Method | Endpoint | Description | Response |
| :--- | :--- | :--- | :--- |
| `GET` | `/api/health` | Service health status for DevOps probes | `{"status": "UP"}` |

### 👥 Users API
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/users` | List all users |
| `GET` | `/api/users/{id}` | Get user details by ID |
| `POST` | `/api/users` | Create a new user |

### 📦 Products API
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/products` | List all products with stock status |
| `GET` | `/api/products/{id}` | Get product details by ID |
| `POST` | `/api/products` | Create a new product |
| `PUT` | `/api/products/{id}` | Update product details and stock |
| `DELETE` | `/api/products/{id}` | Delete product |

### 🛒 Orders API
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/orders` | List all orders with line items |
| `GET` | `/api/orders/{id}` | Get order details by ID |
| `POST` | `/api/orders` | Create multi-item order (decrements stock) |
| `PUT` | `/api/orders/{id}/status` | Update order status (`PENDING`, `CONFIRMED`, `SHIPPED`, `DELIVERED`, `CANCELLED`) |
