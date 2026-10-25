# Parts 4 and 6 — Backend: Java and Spring Boot (line by line)

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md) · Paths are relative to
`order-inventory-platform/backend/`; Java packages are under
`src/main/java/com/example/orderinventory/`.

## 3.1 Architecture of the backend

A single Spring Boot 4.1.1 application (Java 17) in the classic **layered** design:

```text
HTTP ─▶ RequestIdFilter ─▶ Controller (validation, HTTP mapping)
                              │
                              ▼
                         Service (@Transactional business rules)
                              │
                              ▼
                         Repository (Spring Data JPA) ─▶ Hibernate ─▶ HikariCP ─▶ MySQL
Exceptions anywhere ─▶ GlobalExceptionHandler ─▶ ErrorResponse JSON (+ requestId)
```

| Package | Responsibility |
|---|---|
| `controller` | map URLs/HTTP methods to Java methods, validate request DTOs, choose status codes |
| `service` | business rules and transaction boundaries (stock reservation, cancellation, email uniqueness) |
| `repository` | database access (derived queries, row locks) |
| `entity` | JPA mappings of the 4 tables |
| `dto` | request/response shapes (the API contract); entities are never returned directly |
| `exception` | error types and the global HTTP error mapping |
| `config` | CORS and request-id correlation |

**Dependency injection:** every class receives its collaborators through its **constructor** (e.g.
`public OrderService(OrderRepository orderRepository, UserRepository userRepository, ProductRepository
productRepository)`). Spring creates one instance (singleton bean) of each `@Service`, `@RestController`,
`@Component`, `@Configuration` and repository interface, and passes them in. Constructor injection makes
dependencies explicit and `final`, and lets tests construct or mock them.

## 3.2 Build: `pom.xml` (block by block)

| Lines | Block | Meaning |
|---|---|---|
| 7–12 | `<parent>spring-boot-starter-parent 4.1.1` | inherits plugin configuration and a curated, mutually compatible set of dependency versions (so most dependencies have no `<version>`) |
| 14–18 | coordinates | artifact `order-inventory-backend` version `1.0.0` → `target/order-inventory-backend-1.0.0.jar` |
| 21 | `java.version` 17 | compiles for Java 17 (LTS); the runtime image is Temurin 17 JRE |
| 24–25 | `tomcat.version` 11.0.25, `jackson-bom.version` 3.1.7 | **security overrides** of versions managed by the parent, added after Trivy reported vulnerabilities (comment: remove when the parent manages these or newer) |
| 28–30 | `sonar.*` | project key/name for SonarQube; JaCoCo XML path for coverage |
| 36–39 | `spring-boot-starter-webmvc` | Spring MVC + embedded Tomcat + Jackson JSON |
| 41–44 | `spring-boot-starter-data-jpa` | Spring Data JPA + Hibernate + HikariCP pool |
| 46–49 | `spring-boot-starter-validation` | Hibernate Validator for `@Valid`, `@NotNull` … |
| 52–59 | `spring-boot-starter-flyway`, `flyway-mysql` | runs migrations at startup; MySQL dialect support |
| 62–66 | `mysql-connector-j` (`runtime`) | JDBC driver needed only at run time, not for compiling |
| 69–73 | `h2` (`test`) | in-memory database for tests, never packaged |
| 76–87 | `spring-boot-starter-webmvc-test`, `spring-boot-starter-test` (`test`) | MockMvc, JUnit 5, AssertJ, Mockito |
| 92–95 | `spring-boot-maven-plugin` | repackages the JAR into an executable "fat JAR" (`java -jar app.jar`) |
| 98–116 | `jacoco-maven-plugin` | `prepare-agent` instruments tests; `report` in the `test` phase writes `target/site/jacoco/jacoco.xml` used by Jenkins and SonarQube |

`mvn -B clean verify` (Jenkins "Backend Tests") compiles, runs the 29 tests, writes JUnit XML
(`target/surefire-reports`) and the JaCoCo report. The Docker build runs `mvn -B clean package -DskipTests`
because the tests already ran in CI.

## 3.3 Configuration: `src/main/resources/application.properties` (line by line)

| Line(s) | Property | Why |
|---|---|---|
| 4–5 | `spring.application.name`, `server.port=8080` | service name (also appears in ECS logs as `service.name`); container port |
| 8–9 | `server.shutdown=graceful`, `spring.lifecycle.timeout-per-shutdown-phase=20s` | on SIGTERM, Tomcat stops accepting new requests and lets in-flight requests finish (up to 20 s) — part of zero-downtime rollouts |
| 17–20 | `spring.datasource.url/username/password/driver` | **local defaults only** (Docker Compose MySQL on host port 3307, local-only password). On EKS they are overridden by the environment variables `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD` from the Kubernetes Secret (Spring Boot's relaxed binding: env vars override properties) |
| 23 | `hikari.maximum-pool-size=10` | at most 10 DB connections per pod (2 pods → 20; the RDS alarm threshold is 50) |
| 24 | `minimum-idle=2` | keep 2 warm connections |
| 25 | `connection-timeout=5000` | a request waits at most 5 s for a connection → fails fast with an exception mapped to **503** instead of hanging |
| 26 | `validation-timeout=3000` | max time to test a pooled connection |
| 27 | `max-lifetime=1800000` | recycle connections every 30 min (avoids server-side timeouts) |
| 36 | `spring.flyway.locations=classpath:db/migration` | where versioned migrations live; Compose adds `classpath:db/seed` |
| 37–38 | `baseline-on-migrate=true`, `baseline-version=1` | a database that already has tables but no Flyway history is marked as version 1 instead of failing (history: databases created before Flyway) |
| 43 | `spring.jpa.hibernate.ddl-auto=validate` | Hibernate **never changes the schema**; it only checks entities match the tables at startup (mismatch = startup failure, caught by tests) |
| 44 | `spring.jpa.open-in-view=false` | no DB session held open during view rendering; lazy loading outside services fails loudly instead of running hidden queries |
| 45–46 | `show-sql=false`, `format_sql=true` | no SQL in logs by default |
| 53 | `app.cors.allowed-origins=${CORS_ALLOWED_ORIGINS:*}` | read by `CorsConfig`; default `*` (UI is same-origin anyway) |
| 59 | `logging.level.com.example.orderinventory=INFO` | application log level |
| 61 | `logging.structured.ecs.service.environment=${APP_ENVIRONMENT:local}` | adds `service.environment` (`aws`, `minikube`, `local`) to ECS JSON log lines |
| 62 | `logging.pattern.correlation=[%X{requestId:-}] ` | in plain-text logs, prints the MDC `requestId` in every line |

ECS JSON logging itself is switched on by the environment variable `LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs`
(set by the Helm ConfigMap and the Compose logging overlay), not in this file.

## 3.4 Startup and cross-cutting configuration

### `OrderInventoryApplication.java`

```java
@SpringBootApplication
public class OrderInventoryApplication {
    public static void main(String[] args) { SpringApplication.run(OrderInventoryApplication.class, args); }
}
```
`@SpringBootApplication` = `@Configuration` + `@EnableAutoConfiguration` (configure Tomcat, DataSource,
JPA, Flyway, Jackson… from the classpath and properties) + `@ComponentScan` (find beans in this package and
sub-packages). Startup order that matters: DataSource → **Flyway migrates** → Hibernate validates → web server
starts accepting requests. If the database is unreachable at startup, the app fails to start (and Kubernetes
restarts it until the DB is back); once running, DB outages are handled per request (503).

### `config/CorsConfig.java`

```java
public CorsConfig(@Value("${app.cors.allowed-origins:*}") String[] allowedOrigins) { … }
registry.addMapping("/api/**").allowedOrigins(allowedOrigins)
        .allowedMethods("GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH").allowedHeaders("*");
```
Comma-separated property → `String[]`. Only `/api/**` gets CORS headers. In this deployment the browser calls
the same origin, so CORS is not exercised; it exists so the UI could be hosted elsewhere. *Security note:*
`*` is acceptable here because there are no cookies/credentials; with authentication it must be narrowed.

### `config/RequestIdFilter.java` (every line that matters)

```java
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class RequestIdFilter extends OncePerRequestFilter {
```
A servlet filter registered automatically (`@Component`), run **first** (`HIGHEST_PRECEDENCE`) so even errors
from other filters carry the id; `OncePerRequestFilter` guarantees one execution per request.

```java
public static final String HEADER = "X-Request-Id";
public static final String MDC_KEY = "requestId";
private static final Pattern SAFE_ID = Pattern.compile("[A-Za-z0-9._:-]{1,128}");
```
Only short ids of safe characters are accepted from clients. A header containing a newline could otherwise
forge fake log lines (**log injection**); tested by `replacesUnsafeIncomingRequestIds`.

```java
String incoming = request.getHeader(HEADER);
String requestId = incoming != null && SAFE_ID.matcher(incoming).matches() ? incoming : UUID.randomUUID().toString();
MDC.put(MDC_KEY, requestId);
response.setHeader(HEADER, requestId);
try { chain.doFilter(request, response); } finally { MDC.remove(MDC_KEY); }
```
Reuse nginx's id (nginx sets `X-Request-Id $request_id` when it proxies) or create a UUID; store it in the
**MDC** (Mapped Diagnostic Context, a per-thread map that the logger adds to every log line); return it to
the client; always remove it afterwards because Tomcat threads are reused for other requests.

## 3.5 REST endpoints

All bodies are JSON. Examples marked *captured* come from `docs/API.md` (Compose stack, 2026-10-18);
examples marked *illustrative* show the shape only.

| Method | Route | Controller → service → repository | DB effect | Success | Errors | Tests |
|---|---|---|---|---|---|---|
| GET | `/api/health` | `HealthController.getHealth` | none | 200 `{"status":"UP"}` | — | `healthEndpointsReportUp`, `FailurePathWebTest` |
| GET | `/api/health/ready` | `HealthController.getReadiness` → `DataSource.getConnection().isValid(2)` | none | 200 `{"status":"UP","database":"UP"}` | 503 `{"status":"DOWN","database":"DOWN"}` | same |
| GET | `/api/users` | `UserController` → `UserService.getAllUsers` → `findAll` | read | 200 list | 503 | `createsAndFetchesUsers` |
| GET | `/api/users/{id}` | → `getUserById` → `findById` | read | 200 | 400 non-numeric, 404 | same |
| POST | `/api/users` | → `createUser` → `existsByEmail`, `save` | insert `users` | 201 | 400 validation / duplicate email | `rejectsDuplicateEmailCaseInsensitively`, `validatesUserInput` |
| GET | `/api/products` | `ProductController` → `getAllProducts` → `findAll` | read | 200 list with computed `status` | 503 | `productCrudLifecycleWithStockStatus` |
| GET | `/api/products/{id}` | → `getProductById` | read | 200 | 400, 404 | same |
| POST | `/api/products` | → `createProduct` → `save` | insert `products` | 201 | 400 | `validatesProductInput` |
| PUT | `/api/products/{id}` | → `updateProduct` → `findById`, `save` | update | 200 | 400, 404 | lifecycle test |
| DELETE | `/api/products/{id}` | → `deleteProduct` → `existsById`, `deleteById`, `flush` | delete | 204 | 404, **409** if referenced by orders | `deletingProductReferencedByOrdersReturnsConflict`, `lockTimeoutMapsTo409Retry` |
| GET | `/api/orders` | `OrderController` → `getAllOrders` → `findAllByOrderByCreatedAtDesc` | read | 200 newest first, with items | 503 | order tests |
| GET | `/api/orders/{id}` | → `getOrderById` | read | 200 | 400, 404 | `malformedAndInvalidRequests…` |
| POST | `/api/orders` | → `createOrder` → `findById` (user), `findByIdForUpdate` (products), `save` | insert `orders` + `order_items`, update `products.stock_quantity` | 201 | 400 validation / empty items / insufficient stock, 404 unknown user/product, 409 lock timeout, 503 | `creatingOrderDeductsStockAndComputesTotal`, `rejectsOrderExceedingStock…`, `duplicateLines…`, `validatesEachOrderLine`, `rejectsOrdersForUnknownUserOrProduct`, `OrderConcurrencyTest` |
| PUT | `/api/orders/{id}/status` | → `updateOrderStatus` → `findByIdForUpdate` (order), product locks on cancel | update `orders.status`; on cancel update stock | 200 | 400 invalid status / cancelled is final, 404 | `cancellingRestoresStockOnceAndCancelledOrdersAreFinal` |

Captured example (from `docs/API.md`):

```http
POST /api/users
{"name":"Jane Smith","email":"jane.23621@example.com","phone":"+1-555-0199"}

HTTP/1.1 201
X-Request-Id: d3067ae2be233d876eebb10baa712b98
{"id":5,"name":"Jane Smith","email":"jane.23621@example.com","phone":"+1-555-0199","createdAt":"2026-10-18T16:24:27.756846249"}
```

Illustrative order request/response shape (fields from `OrderRequest`, `OrderResponse`, `OrderItemResponse`):

```json
POST /api/orders
{"userId": 1, "items": [{"productId": 3, "quantity": 2}]}

201 Created
{"id": 12, "userId": 1, "userName": "…", "userEmail": "…", "totalAmount": 179.98, "status": "PENDING",
 "createdAt": "…", "items": [{"id": 20, "productId": 3, "productName": "…", "productCategory": "…",
 "quantity": 2, "price": 89.99, "subtotal": 179.98}]}
```

### Controllers (all four follow the same pattern)

```java
@RestController                       // every method's return value is written as JSON
@RequestMapping("/api/orders")        // URL prefix for the class
public class OrderController {
    private final OrderService orderService;
    public OrderController(OrderService orderService) { this.orderService = orderService; }   // DI

    @GetMapping public ResponseEntity<List<OrderResponse>> getAllOrders() { return ResponseEntity.ok(orderService.getAllOrders()); }
    @GetMapping("/{id}") public ResponseEntity<OrderResponse> getOrderById(@PathVariable Long id) { … }
    @PostMapping public ResponseEntity<OrderResponse> createOrder(@Valid @RequestBody OrderRequest request) {
        return new ResponseEntity<>(orderService.createOrder(request), HttpStatus.CREATED); }
    @PutMapping("/{id}/status") public ResponseEntity<OrderResponse> updateOrderStatus(@PathVariable Long id,
            @Valid @RequestBody OrderStatusUpdateRequest request) { … }
}
```
- `@PathVariable Long id`: `/api/orders/abc` cannot be converted → `MethodArgumentTypeMismatchException` → 400.
- `@RequestBody`: Jackson converts JSON to the DTO; malformed JSON or an unknown enum value
  (`{"status":"LOST"}`) → `HttpMessageNotReadableException` → 400.
- `@Valid`: Bean Validation runs on the DTO; violations → `MethodArgumentNotValidException` → 400 with
  field `details`.
- `HttpStatus.CREATED` (201) for creation; `ResponseEntity.noContent()` (204) for delete.
- Controllers contain **no business logic**; they translate HTTP to service calls.

### `HealthController.java` — the health model

```java
@GetMapping public ResponseEntity<HealthResponse> getHealth() { return ResponseEntity.ok(new HealthResponse("UP")); }
```
**Liveness**: answers whenever the JVM and Tomcat work. Used by Kubernetes `startupProbe`/`livenessProbe`,
the ALB health check for the backend target group, the UI header badge and smoke tests. Deliberately **no
DB check**: if the DB is down, restarting pods would not help and would cause restart storms.

```java
@GetMapping("/ready")
public ResponseEntity<HealthResponse> getReadiness() {
    try (Connection connection = dataSource.getConnection()) {
        if (connection.isValid(DB_VALIDATION_TIMEOUT_SECONDS)) return ResponseEntity.ok(new HealthResponse("UP", "UP"));
        log.warn("Readiness check failed: database connection is not valid");
    } catch (Exception ex) { log.warn("Readiness check failed: database unreachable ({})", ex.getClass().getSimpleName()); }
    return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(new HealthResponse("DOWN", "DOWN"));
}
```
**Readiness**: borrows a pooled connection and validates it (2-second timeout). Used by the Kubernetes
`readinessProbe`, the pipeline's in-cluster check and smoke tests. When it fails, Kubernetes removes the pod
from the Service endpoints (no traffic) without restarting it. Only the exception **class name** is logged,
not the message (which can contain the JDBC host). `try-with-resources` returns the connection to the pool.

## 3.6 DTOs and validation

Request DTOs (Jakarta Bean Validation annotations):

| DTO | Field rules |
|---|---|
| `UserRequest` | `name` `@NotBlank @Size(max=100)`; `email` `@NotBlank @Email @Size(max=100)`; `phone` `@Size(max=20)` |
| `ProductRequest` | `name` `@NotBlank @Size(max=150)`; `description` free; `price` `@NotNull @DecimalMin("0.01")`; `stockQuantity` `@NotNull @Min(0)`; `category` `@Size(max=50)` |
| `OrderRequest` | `userId` `@NotNull`; `items` `@NotEmpty List<@Valid OrderItemRequest>` (element-level `@Valid`: each line is validated; container-level `@Valid` is deprecated in Hibernate Validator 9) |
| `OrderItemRequest` | `productId` `@NotNull`; `quantity` `@NotNull @Min(1)` |
| `OrderStatusUpdateRequest` | `status` `@NotNull OrderStatus` (enum) |

The sizes match the column lengths in `V1__initial_schema.sql`, so invalid data is rejected with a clear 400
before reaching the database. Response DTOs: `UserResponse`, `ProductResponse` (adds computed `status`),
`OrderResponse` (adds `userName`, `userEmail`, `items`), `OrderItemResponse` (adds `productName`,
`productCategory`, `subtotal`), `HealthResponse` (`@JsonInclude(NON_NULL)`, so liveness has no `database`
field). `ProductResponse.calculateStatus`:

```java
if (stock == null || stock <= 0) return "OUT_OF_STOCK";
else if (stock <= 10) return "LOW_STOCK";
else return "IN_STOCK";
```
Boundary-tested (`ProductResponseTest`: −1, 0 → OUT; 1, 10 → LOW; 11, 500 → IN; null → OUT).

**Why DTOs instead of entities:** the API shape is independent of the table structure, internal fields are
not exposed, lazy-loaded associations are not serialised accidentally, and validation rules belong to the
request, not the table.

## 3.7 Entities (JPA mapping)

| Entity / table | Key mappings |
|---|---|
| `User` → `users` | `@Id @GeneratedValue(IDENTITY)` (MySQL `AUTO_INCREMENT`); `email` `unique = true, length = 100`; `createdAt` `updatable = false`, set in `@PrePersist` |
| `Product` → `products` | `price` `precision 10, scale 2` (`BigDecimal`, never `double` for money); `description` `TEXT`; `stockQuantity` `Integer`; `@PrePersist` sets `createdAt` and defaults stock to 0 |
| `Order` → `orders` | `@ManyToOne(fetch = EAGER) @JoinColumn(name = "user_id")`; `@Enumerated(EnumType.STRING)` status (stored as text, so reordering the enum cannot corrupt data); `@OneToMany(mappedBy = "order", cascade = ALL, orphanRemoval = true, fetch = EAGER) List<OrderItem> items`; `@PrePersist` sets `createdAt` and default `PENDING` |
| `OrderItem` → `order_items` | `@ManyToOne(fetch = LAZY)` order (the owning side of the FK); `@ManyToOne(fetch = EAGER)` product; `quantity`; `price` = unit price **at the time of ordering** |
| `OrderStatus` | `PENDING, CONFIRMED, SHIPPED, DELIVERED, CANCELLED` |

`cascade = ALL` means saving an `Order` also inserts its `OrderItem`s; `orphanRemoval` deletes items removed
from the list. EAGER loading of items/user/product is acceptable at this data size (every order response needs
them); with large data it would need pagination and fetch joins. Hibernate validates these mappings against
the Flyway-created schema at startup (`ddl-auto=validate`).

## 3.8 Repositories

```java
public interface ProductRepository extends JpaRepository<Product, Long> {
    List<Product> findByStockQuantityLessThanEqual(Integer threshold);
    List<Product> findByCategoryIgnoreCase(String category);
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select p from Product p where p.id = :id")
    Optional<Product> findByIdForUpdate(@Param("id") Long id);
}
```
`JpaRepository` provides `findAll`, `findById`, `save`, `deleteById`, `existsById`, `flush`, `count` … with no
code. Method names like `findByCategoryIgnoreCase` are turned into queries by Spring Data. `findByIdForUpdate`
is the key method: `PESSIMISTIC_WRITE` makes Hibernate issue `SELECT … FOR UPDATE` on MySQL, taking an
**exclusive row lock** held until the transaction ends. `OrderRepository` has the same method for orders and
`findAllByOrderByCreatedAtDesc` (newest first). `findByStockQuantityLessThanEqual`, `findByCategoryIgnoreCase`,
`findByUserId`, `findByStatus`, `countByStatus`, `UserRepository.findByEmail` and
`OrderItemRepository.findByOrderId` are declared but **not used** by the current services (available for
future features; harmless).

## 3.9 Services, transactions and concurrency

### Transaction boundaries

All three services are annotated `@Service @Transactional` at class level: **every public method runs in one
database transaction** (propagation `REQUIRED`). Read methods use `@Transactional(readOnly = true)` (lets
Hibernate skip dirty checking). Spring rolls back on any `RuntimeException`; `BadRequestException` and
`ResourceNotFoundException` extend `RuntimeException`, so when a business rule fails **nothing is written**
(e.g. an order whose second line has insufficient stock does not keep the deduction of the first line).
*In general*, MySQL InnoDB's default isolation is REPEATABLE READ, but locking reads (`FOR UPDATE`) always read
the latest committed row version, which is what the stock check needs.

### `OrderService.createOrder` (line by line)

```java
User user = userRepository.findById(request.getUserId())
        .orElseThrow(() -> new ResourceNotFoundException("User not found with id: " + request.getUserId()));
```
Unknown user → 404.

```java
if (request.getItems() == null || request.getItems().isEmpty()) throw new BadRequestException("Order must contain at least one item");
```
Defensive check (the DTO's `@NotEmpty` normally catches this first) → 400.

```java
Map<Long, Product> lockedProducts = new HashMap<>();
request.getItems().stream().map(OrderItemRequest::getProductId).distinct().sorted()
    .forEach(productId -> lockedProducts.put(productId, productRepository.findByIdForUpdate(productId)
        .orElseThrow(() -> new ResourceNotFoundException("Product not found with id: " + productId))));
```
1. Collect the distinct product ids of the order and **sort them ascending**.
2. Lock each product row with `SELECT … FOR UPDATE`, in that order, before any stock is checked.
- *Why lock first:* the stock read and the stock write must be atomic with respect to other orders.
- *Why sorted:* if order A locks product 1 then 2 while order B locks 2 then 1, each would wait for the other
  forever (**deadlock**). Locking in one global order (ascending id) makes that impossible.
- *Why `distinct` + map:* the same product on two lines is locked once, and both lines deduct from the **same
  object**, so the second line sees the reduced stock (tested: `duplicateLinesForSameProductAreCheckedAgainstCombinedStock`
  — two lines of 2 against stock 3 → 400, stock unchanged).

```java
Order order = new Order(); order.setUser(user); order.setStatus(OrderStatus.PENDING);
BigDecimal totalAmount = BigDecimal.ZERO; List<OrderItem> orderItems = new ArrayList<>();
for (OrderItemRequest itemReq : request.getItems()) {
    Product product = lockedProducts.get(itemReq.getProductId());
    if (product.getStockQuantity() < itemReq.getQuantity()) {
        log.warn("Order rejected for user {}: insufficient stock for product {} (available {}, requested {})", …);
        throw new BadRequestException("Insufficient stock for product '" + product.getName() + "'. Available: " + … );
    }
    product.setStockQuantity(product.getStockQuantity() - itemReq.getQuantity());
    productRepository.save(product);
    OrderItem orderItem = new OrderItem(); orderItem.setOrder(order); orderItem.setProduct(product);
    orderItem.setQuantity(itemReq.getQuantity()); orderItem.setPrice(product.getPrice());
    orderItems.add(orderItem);
    totalAmount = totalAmount.add(product.getPrice().multiply(BigDecimal.valueOf(itemReq.getQuantity())));
}
order.setTotalAmount(totalAmount); order.setItems(orderItems);
Order savedOrder = orderRepository.save(order);
log.info("Order {} created for user {}: {} line(s), total {}", …);
return mapToResponse(savedOrder);
```
- Stock check and deduction happen **while holding the lock**.
- The warning log line contains ids and numbers only (no email = no personal data in logs); it is the event
  traced in Kibana by `requestId` (evidence `elk-eks-2026-10-19.txt`).
- Price is copied into the order line, so later price changes do not alter past orders.
- Totals use `BigDecimal` (exact decimal arithmetic).
- `orderRepository.save(order)` inserts the order and, through `cascade = ALL`, its items.
- When the method returns, Spring **commits**: stock updates, order and items become visible together and the
  row locks are released.

#### Two requests for the last unit (the overselling question)

Stock of product 7 = 1. Requests A and B arrive at the same time on different pods (both pods use the same RDS).

| Time | Transaction A | Transaction B |
|---|---|---|
| t1 | `SELECT … FROM products WHERE id=7 FOR UPDATE` → gets the lock, reads stock 1 | — |
| t2 | — | `SELECT … FOR UPDATE` on id 7 → **blocks**, waiting for A's lock |
| t3 | 1 ≥ 1 → stock := 0, insert order + item | still waiting |
| t4 | **COMMIT** → lock released | lock granted; reads the **committed** stock 0 |
| t5 | 201 Created | 0 < 1 → `BadRequestException` → **rollback** → 400 "Insufficient stock … Available: 0, Requested: 1" |

Exactly one buyer succeeds. If A had rolled back instead, B would have read stock 1 and succeeded. If B waits
longer than InnoDB's lock wait timeout (*general knowledge:* 50 s by default), the driver raises a lock
timeout → Spring `PessimisticLockingFailureException` → **409 "Please retry"**. Two extra safety nets: the
`CHECK (stock_quantity >= 0)` constraint from V2 makes negative stock impossible even if code were wrong
(it would fail the update), and `OrderConcurrencyTest` proves the behaviour: 8 threads each order 1 unit of
a product with stock 3 → exactly 3 successes, stock 0, 3 orders. The test was mutation-checked (removing the
lock makes it fail — `docs/TESTING.md`). Limitation: the test runs on H2 (MySQL mode), not on MySQL itself.

The mechanism is **pessimistic locking**. There is **no** optimistic locking (`@Version`) and **no**
`SERIALIZABLE` isolation in this code.

### `OrderService.updateOrderStatus`

```java
Order order = orderRepository.findByIdForUpdate(id).orElseThrow(() -> new ResourceNotFoundException(…));
OrderStatus currentStatus = order.getStatus(); OrderStatus newStatus = request.getStatus();
if (currentStatus == OrderStatus.CANCELLED && newStatus != OrderStatus.CANCELLED) {
    log.warn(…); throw new BadRequestException("Order " + id + " is cancelled and cannot be moved to " + newStatus);
}
if (newStatus == OrderStatus.CANCELLED && currentStatus != OrderStatus.CANCELLED) {
    order.getItems().stream().sorted(Comparator.comparing(item -> item.getProduct().getId()))
         .forEach(item -> { Product product = productRepository.findByIdForUpdate(item.getProduct().getId())…;
                            product.setStockQuantity(product.getStockQuantity() + item.getQuantity());
                            productRepository.save(product); });
}
…
order.setStatus(newStatus); Order updatedOrder = orderRepository.save(order); return mapToResponse(updatedOrder);
```
- The **order row is locked first**: if two "cancel" requests arrive together, the second waits, then sees
  status `CANCELLED` and does not restock again ("restore stock exactly once").
- **Cancelled is final**: re-opening would have to re-reserve stock that may have been sold meanwhile.
  Setting `CANCELLED` on an already-cancelled order is accepted (idempotent, no restock).
- Products are locked in ascending id order again (deadlock avoidance with concurrent orders).
- Other transitions are not restricted (e.g. `DELIVERED → PENDING` is allowed) — only the cancellation rule is
  enforced. Mention this honestly if asked about a full state machine.

### `ProductService` and `UserService`

- `createProduct`/`updateProduct` trim strings, turn missing stock into 0, and save. Updating stock directly
  is an administrative action (not locked); order flows always lock.
- `deleteProduct`: `existsById` (404 if missing) → `deleteById` → **`flush()`** — forces the SQL `DELETE` now so
  a foreign-key violation (product used in `order_items`) surfaces inside the method as
  `DataIntegrityViolationException` → **409** with a clear message, instead of an error at commit time.
- `createUser`: `email.trim().toLowerCase(Locale.ROOT)` **before** `existsByEmail`, so `Jane@X.com` and
  `jane@x.com` are duplicates (400). `Locale.ROOT` avoids locale-specific lower-casing bugs (e.g. Turkish "I").
  The database `UNIQUE` constraint is a second guard if two requests race (→ 409 via
  `DataIntegrityViolationException`).

## 3.10 Error handling: `GlobalExceptionHandler` and `ErrorResponse`

`ErrorResponse` fields: `timestamp`, `status`, `error`, `message`, `details` (field errors), `path`,
`requestId` — read from the MDC in the constructor, so every error body carries the correlation id.

| Exception (handler method) | Status | Message to client | Logged |
|---|---|---|---|
| `ResourceNotFoundException` | 404 | the exception message | — |
| `BadRequestException` | 400 | the exception message | (service logs WARN for business rejections) |
| `MethodArgumentNotValidException` | 400 "Validation Failed" | "Input validation failed…" + `details: ["field: message", …]` | — |
| `IllegalArgumentException` | 400 | message | — |
| `HttpMessageNotReadableException` | 400 | "Malformed request body or invalid field value" | — |
| `MethodArgumentTypeMismatchException` | 400 | "Invalid value for parameter 'id'" | — |
| `DataIntegrityViolationException` | 409 | "The request conflicts with existing data …" | WARN with root-cause class only |
| `PessimisticLockingFailureException` | 409 | "The resource is being updated by another request. Please retry." | WARN |
| `CannotCreateTransactionException`, `DataAccessResourceFailureException` | **503** | "The database is temporarily unavailable. Please retry shortly." | ERROR with method/URI |
| Spring MVC exceptions implementing `org.springframework.web.ErrorResponse` (no handler → 404, wrong method → 405, unsupported media type → 415) | their own status | Spring's detail text | — |
| any other `Exception` | 500 | "An unexpected server error occurred" | ERROR **with stack trace** (server side only) |

**What happens if the database becomes unavailable during an order?** HikariCP cannot provide a connection
within 5 s → Spring throws `CannotCreateTransactionException` when opening the transaction → 503 with the
generic message (verified on AWS: RDS reboot → 3 × 503 on `/api/products` for ~1 s, liveness 200 throughout,
0 pod restarts — `docs/evidence/aws-rds-interruption-2026-10-19.txt`). If the connection breaks after the
transaction started, the transaction is rolled back, so no half-written order exists; the client gets an
error and can retry. Meanwhile readiness fails, so Kubernetes and the ALB stop sending new requests to the
affected pods until the DB is back.

## 3.11 Tests (29, JUnit 5)

| Test class | Type | What it proves |
|---|---|---|
| `ApiIntegrationTest` (14) | `@SpringBootTest` + MockMvc + H2 (real context, real migrations) | health, user create/get, duplicate email (case-insensitive), user validation, product CRUD + stock status, product validation, 409 delete, order totals and stock deduction, oversell rejected without changing stock, duplicate lines vs combined stock, per-line validation (`items[0].quantity`, `items[1].productId`), unknown user/product 404, empty items 400, cancel restores once + cancelled final, malformed JSON / unknown enum / non-numeric id / unknown route / wrong method / missing resource → proper 4xx (never 500) |
| `FailurePathWebTest` (4) | `@WebMvcTest` slice with `@MockitoBean DataSource` and `ProductService` | readiness 503 + liveness 200 during DB outage; DB outage → 503 without leaking `secret-host`; lock timeout → 409 "retry"; unexpected error → generic 500 |
| `OrderConcurrencyTest` (1) | `@SpringBootTest`, 8 threads + `CountDownLatch` start gate | no overselling under real concurrency |
| `RequestCorrelationTest` (3) | MockMvc | id generated (UUID format); incoming `nginx-abc123` propagated to header and error body; unsafe id with a newline replaced |
| `ProductResponseTest` (7) | parameterised unit test | stock status boundaries |

`application-test.properties` switches the `test` profile to H2 in MySQL mode
(`jdbc:h2:mem:…;MODE=MySQL;DATABASE_TO_LOWER=TRUE`), keeps Flyway (the real V1/V2 migrations run) and
`ddl-auto=validate` (so entity/schema mismatches fail the build). `@BeforeEach cleanDatabase()` deletes all
rows in FK order before each test for isolation. Result: 29/29, JaCoCo lines 70.97 %, branches 75 %
(`docs/TESTING.md`), re-run in every Jenkins build (evidence for build #7 lists each class and count).

## 3.12 Build and run

| Where | Command | Result |
|---|---|---|
| Developer | `mvn -B clean verify` | tests + `target/order-inventory-backend-1.0.0.jar` + coverage |
| Docker stage 1 | `mvn -B dependency:go-offline` then `mvn -B clean package -DskipTests` | JAR in the builder image |
| Docker stage 2 | `ENTRYPOINT ["sh","-c","exec java $JAVA_OPTS -jar app.jar"]` | JVM as PID 1, heap = 75 % of the container limit, exits on OOM |

## 3.13 Viva questions (backend)

| Question | Answer |
|---|---|
| How does the system prevent overselling? | Order creation runs in one transaction and locks each product row with `SELECT … FOR UPDATE` (ascending id) before checking and deducting stock; a second buyer waits and then sees the committed stock. A DB `CHECK` constraint forbids negative stock. Proven by `OrderConcurrencyTest`. |
| Why pessimistic and not optimistic locking? | Contention is on few hot rows (popular products) and a failed optimistic attempt would have to be retried by the client; waiting briefly for a row lock gives a simple, correct outcome. Optimistic locking (`@Version`) is better when conflicts are rare and reads dominate. |
| Why lock in ascending id order? | To prevent deadlocks between orders containing the same products in different orders. |
| What is `@Transactional` doing? | Opens a DB transaction before the method and commits after it; rolls back on runtime exceptions, so partial orders cannot exist. |
| What is the difference between 400, 404, 409, 503, 500 here? | Client mistake / missing record / conflict with current data or lock contention (retry) / database temporarily unavailable (retry) / unexpected bug (generic message, stack trace only in logs). |
| Why `ddl-auto=validate`? | Flyway owns schema changes (versioned, reviewable); Hibernate must never alter a production schema. |
| Why `BigDecimal` for prices? | Binary floating point cannot represent 0.10 exactly; money needs exact decimal arithmetic. |
| What is MDC? | A per-thread context map; values in it (here `requestId`) are added to every log line of that request. |
| Why does liveness not check the database? | A DB outage is not fixed by restarting the app; it would cause restart storms. Readiness removes the pod from traffic instead. |
| What if two users register the same email simultaneously? | Both may pass `existsByEmail`; the `UNIQUE` index rejects the second insert → `DataIntegrityViolationException` → 409. |
| Is the backend a microservice? | It is one service (modular monolith) with users/products/orders sharing one DB transaction; see the handbook §2.9. |
