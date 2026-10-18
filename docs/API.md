# REST API

Base path: `/api` (same origin as the UI: nginx in Docker Compose, the ALB on EKS, the Vite proxy in
development). All bodies are JSON. Every response carries an `X-Request-Id` header; error bodies repeat
it as `requestId` — quote it when reporting a problem (see docs/RUNBOOKS.md §6).

The examples below were captured from the running Docker Compose stack on 2026-10-18 (timestamps and
ids are from that run).

## Endpoints

| Method | Path | Success | Errors |
|---|---|---|---|
| GET | `/api/health` | 200 `{"status":"UP"}` (liveness, no DB check) | — |
| GET | `/api/health/ready` | 200 `{"status":"UP","database":"UP"}` | 503 `{"status":"DOWN","database":"DOWN"}` |
| GET | `/api/users` · `/api/users/{id}` | 200 | 400 bad id, 404 |
| POST | `/api/users` | 201 | 400 validation / duplicate email (case-insensitive) |
| GET | `/api/products` · `/api/products/{id}` | 200 (includes computed `status`) | 400, 404 |
| POST | `/api/products` | 201 | 400 validation |
| PUT | `/api/products/{id}` | 200 | 400, 404 |
| DELETE | `/api/products/{id}` | 204 | 404, 409 referenced by orders |
| GET | `/api/orders` · `/api/orders/{id}` | 200 (newest first, with items) | 400, 404 |
| POST | `/api/orders` | 201 (stock reserved atomically) | 400 validation / insufficient stock, 404 unknown user/product |
| PUT | `/api/orders/{id}/status` | 200 (`CANCELLED` restores stock once) | 400 invalid status / cancelled order is final, 404 |

Common error statuses: 405 unsupported method, 409 lock contention (retry), 503 database unavailable,
500 unexpected (generic message; details only in server logs).

Product `status`: `OUT_OF_STOCK` (≤ 0), `LOW_STOCK` (1–10), `IN_STOCK` (> 10).

## Examples

```http
POST /api/users
{"name":"Jane Smith","email":"jane.23621@example.com","phone":"+1-555-0199"}

HTTP/1.1 201
X-Request-Id: d3067ae2be233d876eebb10baa712b98
{"id":5,"name":"Jane Smith","email":"jane.23621@example.com","phone":"+1-555-0199","createdAt":"2026-10-18T16:24:27.756846249"}
```

```http
POST /api/users
{"name":"","email":"not-an-email"}

HTTP/1.1 400
{"status":400,"error":"Validation Failed","message":"Input validation failed for one or more fields",
 "details":["name: User name is required","email: Invalid email format"],
 "path":"/api/users","requestId":"7660bc514c86b8863631726cb5035e11","timestamp":"2026-10-18T16:24:27.91432771"}
```

```http
POST /api/products
{"name":"USB-C Hub","description":"7-in-1 hub","price":39.99,"stockQuantity":12,"category":"Accessories"}

HTTP/1.1 201
{"id":5,"name":"USB-C Hub","description":"7-in-1 hub","price":39.99,"stockQuantity":12,"category":"Accessories",
 "createdAt":"2026-10-18T16:24:28.04300487","status":"IN_STOCK"}
```

```http
POST /api/orders
{"userId":5,"items":[{"productId":5,"quantity":2}]}

HTTP/1.1 201
{"id":4,"userId":5,"userName":"Jane Smith","userEmail":"jane.23621@example.com","totalAmount":79.98,"status":"PENDING",
 "createdAt":"2026-10-18T16:24:29.364350755",
 "items":[{"id":4,"productId":5,"productName":"USB-C Hub","productCategory":"Accessories","quantity":2,"price":39.99,"subtotal":79.98}]}
```

```http
POST /api/orders
{"userId":5,"items":[{"productId":5,"quantity":999}]}

HTTP/1.1 400
{"status":400,"error":"Bad Request","message":"Insufficient stock for product 'USB-C Hub'. Available: 10, Requested: 999",
 "details":null,"path":"/api/orders","requestId":"ac68bdbb4094dc4622acf5f570a3c90b","timestamp":"2026-10-18T16:24:29.691790193"}
```

```http
PUT /api/orders/4/status
{"status":"CANCELLED"}          → 200, stock of product 5 goes back from 10 to 12

PUT /api/orders/4/status
{"status":"PENDING"}

HTTP/1.1 400
{"status":400,"error":"Bad Request","message":"Order 4 is cancelled and cannot be moved to PENDING", ...}
```

```http
DELETE /api/products/5

HTTP/1.1 409
{"status":409,"error":"Conflict","message":"The request conflicts with existing data (for example, the record is referenced by existing orders or already exists)", ...}
```

```http
GET /api/products/abc   → 400 {"message":"Invalid value for parameter 'id'", ...}
GET /api/orders/999999  → 404 {"message":"Order not found with id: 999999", ...}
```

PowerShell equivalent:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:3000/api/products -ContentType 'application/json' `
  -Body '{"name":"USB-C Hub","price":39.99,"stockQuantity":12,"category":"Accessories"}'
```
