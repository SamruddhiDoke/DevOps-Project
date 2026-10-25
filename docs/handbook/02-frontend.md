# Parts 4–5 — Frontend: React, JavaScript and Vite (line by line)

[← Handbook](../COMPLETE_PROJECT_HANDBOOK_AND_VIVA_GUIDE.md) · All paths below are relative to
`order-inventory-platform/frontend/`.

## 2.1 What the frontend is

A **single-page application (SPA)** written in React 18 (JSX), built by **Vite** into static files
(`dist/index.html` + fingerprinted JS/CSS in `dist/assets/`) and served by **nginx** inside the frontend
container. The browser downloads the app once; navigation between pages happens in the browser (React
Router), and data comes from the backend REST API over `fetch()` calls to the **same origin** under `/api`.

Component tree (from `src/App.jsx`):

```text
<StrictMode> <BrowserRouter> <App>
  /login                  → <Login/>
  (layout) <AppLayout>    → <Sidebar/> + <main><Outlet/></main>
      /dashboard          → <Dashboard/>  → <Header/>, <StatCard/>×n, <StatusBadge/>, <Modal/>
      /products           → <Products/>   → <Header/>, <Toast/>, <Modal/>, <ConfirmDialog/>, <StatusBadge/>
      /orders             → <Orders/>     → <Header/>, <Toast/>, <Modal/>×3, <StatusBadge/>
      /users              → <Users/>      → <Header/>, <Toast/>, <Modal/>×2
      /                   → <Navigate to="/dashboard">
  *                       → <Navigate to="/dashboard">
```

State management: **local component state only** (`useState`, `useCallback`, `useEffect`) plus one custom
hook (`useToasts`). There is no Redux/Context store: every page loads the data it needs from the API, and
after each change it reloads from the API, so the server stays the single source of truth.

## 2.2 Build and tooling files

### `package.json`

```json
"type": "module",
```
Node treats `.js` files as ES modules (`import`/`export`), which `vite.config.js` and `eslint.config.js` use.

```json
"scripts": { "dev": "vite", "build": "vite build", "preview": "vite preview",
             "test": "vitest run", "lint": "eslint . --max-warnings=0",
             "test:coverage": "vitest run --coverage" }
```
| Script | Runs | Who uses it |
|---|---|---|
| `dev` | Vite dev server (port 5173, hot reload) | developer |
| `build` | production bundle into `dist/` | Dockerfile stage 1, Jenkins "Frontend Build" |
| `preview` | serves `dist/` locally | developer |
| `test` | Vitest once (not watch mode) | developer, CI |
| `lint` | ESLint; `--max-warnings=0` turns any warning into a failure | Jenkins |
| `test:coverage` | Vitest + V8 coverage (LCOV for SonarQube) | developer; Jenkins runs the equivalent `npx vitest run --coverage …` |

Dependencies: `react`, `react-dom` (rendering), `react-router-dom` (routing) are shipped to the browser.
Dev dependencies are only for building/testing (Vite, Vitest, jsdom, Testing Library, ESLint plugins).
`"engines": {"node": ">=20.19.0"}` documents the minimum Node version; the Jenkinsfile enforces it with a
small `node -e` check in "Environment Check".

*If removed/changed:* without `--max-warnings=0` lint warnings would not fail CI; without `"type": "module"`
the config files would fail to load.

### `vite.config.js`

```js
export default defineConfig({
  plugins: [react()],
```
`@vitejs/plugin-react` compiles JSX and enables React Fast Refresh in development.

```js
  server: { port: 5173, host: true,
    proxy: { '/api': { target: process.env.VITE_DEV_API_PROXY || 'http://localhost:8080', changeOrigin: true } } },
```
In development the browser talks to Vite on 5173. Requests to `/api/...` are forwarded to the backend
(default `localhost:8080`, overridable with `VITE_DEV_API_PROXY`). This **mirrors production** where nginx or
the ALB route `/api`, so `api.js` can always use the relative path `/api` and never needs CORS.
`host: true` listens on all interfaces (useful inside containers/VMs). `changeOrigin` rewrites the `Host`
header to the target.

```js
  test: { environment: 'jsdom', setupFiles: './src/test/setup.js', restoreMocks: true,
    coverage: { provider: 'v8', reporter: ['text-summary', 'lcov'],
      include: ['src/**/*.{js,jsx}'], exclude: ['src/test/**', 'src/**/*.test.{js,jsx}', 'src/main.jsx'] } },
```
Vitest runs tests in **jsdom** (a simulated browser DOM in Node). `restoreMocks` resets `vi.fn` mocks between
tests. Coverage writes `coverage/lcov.info`, which SonarQube reads (`sonar-project.properties`). Test files and
the bootstrap file are excluded so they do not distort coverage.

### `eslint.config.js`

Flat config (ESLint 9). Line by line: ignore `dist` and `coverage`; for all `.js/.jsx` files use the latest
ECMAScript, ES modules, browser + Node globals and JSX parsing; detect the React version; enable
`js.configs.recommended` (bugs such as unused variables), `react.configs.recommended` and `jsx-runtime`
(no need to import React for JSX), `react-hooks` recommended (rules of hooks, exhaustive dependencies);
turn off `react/prop-types` (no PropTypes in this project) and warn on components exported together with
non-components (Fast Refresh limitation). *Viva:* "Why lint in CI?" — it blocks a class of runtime bugs
(e.g. a missing hook dependency causing stale data) before tests even run.

### `index.html`

The SPA shell: `<div id="root"></div>` is where React renders; `<script type="module" src="/src/main.jsx">`
is the entry Vite follows to build the bundle (Vite rewrites it to `/assets/index-<hash>.js` in `dist/`).
The favicon is an inline SVG data URI; the Inter font is loaded from Google Fonts (the only external
resource; if offline, the browser falls back to the system font).

### `sonar-project.properties`

`sonar.sources=src` and `sonar.tests=src` with `sonar.test.inclusions`/`sonar.exclusions` so test files are
analysed as tests, not as production code; `sonar.javascript.lcov.reportPaths=coverage/lcov.info` feeds
coverage. Read by `sonar-scanner` in the Jenkins "Code Quality" stage.

## 2.3 Entry point and routing

### `src/main.jsx`

```jsx
ReactDOM.createRoot(document.getElementById('root')).render(
  <StrictMode><BrowserRouter><App /></BrowserRouter></StrictMode>);
```
1. `createRoot` (React 18 concurrent root) attaches React to `#root`.
2. `StrictMode` runs extra development-only checks (double-invokes effects in dev to reveal side-effect bugs;
   no effect in production builds).
3. `BrowserRouter` uses the HTML5 History API, so URLs look like `/orders` (not `/#/orders`). This is why
   nginx needs the SPA fallback (`try_files $uri $uri/ /index.html`): when the user refreshes `/orders`, the
   server has no file `orders`, so it returns `index.html` and React Router renders the page.
4. `import './index.css'` — Vite bundles the stylesheet.

### `src/App.jsx`

```jsx
function AppLayout() {
  return (<div className="app-container"><Sidebar /><main className="main-content"><Outlet /></main></div>);
}
```
A **layout route**: the sidebar is rendered once and `<Outlet/>` is replaced by the matched child page.

```jsx
<Route path="/login" element={<Login />} />
<Route element={<AppLayout />}>
  <Route path="/dashboard" element={<Dashboard />} /> … <Route path="/users" element={<Users />} />
  <Route path="/" element={<Navigate to="/dashboard" replace />} />
</Route>
<Route path="*" element={<Navigate to="/dashboard" replace />} />
```
`/login` is outside the layout (full-screen). `Navigate … replace` redirects without adding a history entry.
The catch-all `*` sends unknown URLs to the dashboard (tested in `App.test.jsx`: "falls back to the dashboard
for unknown routes").

## 2.4 API communication — `src/services/api.js` (line by line)

```js
export const API_BASE_URL = (import.meta.env.VITE_API_BASE_URL || '/api').replace(/\/+$/, '');
```
- `import.meta.env.VITE_API_BASE_URL` is a **build-time** variable: Vite replaces it with a constant when it
  builds the bundle. It is not read at runtime. If unset (the normal case), the base is the **relative**
  `/api`, i.e. the same host that served the page.
- `.replace(/\/+$/, '')` removes trailing slashes so `"/api/" + "/users"` cannot become `//users`.

```js
const REQUEST_TIMEOUT_MS = 15000;
export async function request(endpoint, options = {}) {
  const url = `${API_BASE_URL}${endpoint}`;
  const defaultHeaders = { 'Content-Type': 'application/json', 'Accept': 'application/json' };
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  const config = { ...options, signal: controller.signal,
                   headers: { ...defaultHeaders, ...options.headers } };
```
Every call sends and accepts JSON. `fetch` has no timeout of its own, so an `AbortController` aborts the
request after 15 s; the caller's headers override the defaults (spread order).

```js
  try {
    const response = await fetch(url, config);
    if (response.status === 204) { return null; }
```
204 No Content (product delete) has no body; returning `null` avoids a JSON parse error.

```js
    const isJson = (response.headers.get('content-type') || '').includes('application/json');
    const data = isJson ? await response.json().catch(() => null) : null;
```
Parses JSON only when the server says it is JSON; a broken body becomes `null` instead of throwing.

```js
    if (!response.ok) {
      const errorMessage = (data?.details && data.details.length ? data.details.join(', ') : data?.message)
                           || `Request failed with status ${response.status}`;
      const error = new Error(errorMessage); error.status = response.status; error.data = data; throw error;
    }
```
For 4xx/5xx the message shown to the user is, in order of preference: the backend's field-level validation
`details` (e.g. `price: Price must be greater than 0`), the backend `message`, or a generic text with the
status. `status` and the full `data` (including `requestId`) are attached for callers/tests.

| Backend status | Backend body (`GlobalExceptionHandler`) | What the user sees |
|---|---|---|
| 400 validation | `details: ["field: message", …]` | the joined field messages in a red toast |
| 400 business rule | `message: "Insufficient stock for product 'X'. Available: 2, Requested: 5"` | that message |
| 404 | `message: "Order not found with id: 99"` | that message |
| 409 | "The request conflicts with existing data …" or "… being updated by another request. Please retry." | that message (e.g. deleting a product that has orders) |
| 503 | "The database is temporarily unavailable. Please retry shortly." | that message; header badge stays "API Online" because liveness does not check the DB |
| 500 | "An unexpected server error occurred" | that message (no internals) |

```js
    if (!isJson) {
      const error = new Error('Unexpected response from API. Check that /api is routed to the backend service.');
      error.status = response.status; throw error;
    }
    return data;
```
A **2xx response that is not JSON** means `/api` was not routed to the backend (for example an SPA fallback
returned `index.html` with 200). Treating it as an error makes routing mistakes visible instead of showing
empty tables (tested: "treats a 200 HTML response (unrouted /api SPA fallback) as an error").

```js
  } catch (err) {
    if (err.name === 'AbortError') throw new Error('The backend did not respond in time. Please try again.');
    if (err instanceof TypeError) throw new Error('Unable to connect to backend server. Please verify the Spring Boot service is running.');
    throw err;
  } finally { clearTimeout(timeoutId); }
```
`fetch` rejects with a `TypeError` for network failures (wording differs per browser), so the type is checked,
not the text. `finally` always clears the timer.

The four API objects map 1:1 to backend endpoints: `healthApi.getHealth` → `GET /api/health`;
`usersApi.getAll/getById/create`; `productsApi.getAll/getById/create/update/delete`;
`ordersApi.getAll/getById/create/updateStatus` (`PUT /api/orders/{id}/status` with body `{"status": …}`).
Bodies are serialised with `JSON.stringify`.

**Why no secrets in frontend environment variables:** every `VITE_*` value is compiled into the JavaScript
that is downloaded by every visitor, who can read it in the browser's developer tools. The frontend therefore
holds no credentials; the database password exists only in the backend pod (from a Kubernetes Secret).

## 2.5 Hook and components

### `src/hooks/useToasts.js`

```js
const [toasts, setToasts] = useState([]);
const nextId = useRef(0);
const removeToast = useCallback((id) => { setToasts((prev) => prev.filter((t) => t.id !== id)); }, []);
const addToast = useCallback((message, type = 'info') => {
  nextId.current += 1; const id = nextId.current;
  setToasts((prev) => [...prev, { id, message, type }]);
  setTimeout(() => removeToast(id), TOAST_DURATION_MS);
}, [removeToast]);
```
- `useRef` counter gives unique ids even for two toasts in the same millisecond (a `Date.now()` id would
  collide; tested).
- Functional `setToasts(prev => …)` avoids stale state when several toasts are added quickly.
- `useCallback` with stable dependencies keeps `addToast` the **same function across renders**. Pages use
  `addToast` inside `fetchData`'s `useCallback`, which is a dependency of `useEffect`; an unstable `addToast`
  would re-create `fetchData` every render and the effect would reload data in an endless loop (tested:
  "keeps callbacks stable across renders").

### Components (`src/components/`)

| Component | Logic worth knowing |
|---|---|
| `Header.jsx` | On mount calls `healthApi.getHealth()` and then every 15 s (`setInterval`); shows **API Online / Offline / Connecting…**. `isMounted` flag + `clearInterval` in the cleanup prevent state updates after unmount. It uses **liveness** (`/api/health`), so a DB outage does not turn it red. |
| `Sidebar.jsx` | `NavLink` with a class callback `({ isActive }) => …` highlights the current page. |
| `Modal.jsx` | renders nothing when closed; Escape key listener added/removed in an effect; clicking the overlay closes, clicking inside (`stopPropagation`) does not. |
| `ConfirmDialog.jsx` | `Modal` with a message and Cancel/Confirm buttons; danger styling by default. |
| `StatCard.jsx` | presentational card; colours via CSS custom properties. |
| `StatusBadge.jsx` | maps `IN_STOCK`/`LOW_STOCK`/`OUT_OF_STOCK` and the 5 order statuses to labelled badges. |
| `Toast.jsx` | renders the toast list with an icon per type and a dismiss button. |
| `Icons.jsx` | inline SVG icon components (drawing paths only). |

## 2.6 Pages

### Shared data-loading pattern (Dashboard, Orders)

```js
const fetchData = useCallback(async () => {
  try {
    const results = await Promise.allSettled([ordersApi.getAll(), usersApi.getAll(), productsApi.getAll()]);
    const [ordersData, usersData, productsData] = results.map((r) => r.status === 'fulfilled' ? r.value || [] : []);
    setOrders(ordersData); setUsers(usersData); setProducts(productsData);
    const failure = results.find((r) => r.status === 'rejected');
    if (failure) { addToast(failure.reason?.message || 'Failed to fetch orders data', 'error'); }
  } finally { setLoading(false); }
}, [addToast]);
useEffect(() => { fetchData(); }, [fetchData]);
```
- `Promise.allSettled` (not `Promise.all`): the three requests run **in parallel**, and one failure does not
  hide the data of the others.
- The initial state is `loading = true`, so the effect only sets state **after** awaiting (comment in the
  code: avoids cascading renders flagged by the hooks lint rules). Manual refresh sets `loading` first.
- Loading, empty and error states: a spinner while loading; an "empty state" box with a hint when the
  (filtered) list is empty; a toast (Orders/Products/Users) or a banner (Dashboard) on errors.

### `Dashboard.jsx`

Computed values: `lowStockProducts = products.filter(p => p.stockQuantity <= 10)`; `recentOrders =
orders.slice(0, 5)` (the backend already returns newest first: `findAllByOrderByCreatedAtDesc`);
`totalRevenue` = sum of `totalAmount` of orders whose status is **not** `CANCELLED`. A failed request shows
`Failed to fetch dashboard data: <message>` instead of silently showing zeros (tested).

### `Products.jsx`

- `validateForm`: name required; price > 0; stock ≥ 0 (mirrors the backend `@DecimalMin("0.01")`, `@Min(0)`).
- `handleSubmit` builds a **typed payload** (`parseFloat`, `parseInt`, trimmed strings, empty → `null`) and
  calls `create` or `update` depending on `isEditing`, then reloads the list.
- Delete asks for confirmation (`ConfirmDialog`); a **409** from the backend (product referenced by orders)
  is shown as the backend message (tested: "shows the backend message when deletion is refused (409)").

### `Users.jsx`

`validateForm` requires a name and an email matching `/\S+@\S+\.\S+/`; the payload lower-cases the email;
the backend also normalises it and rejects duplicates case-insensitively (tested in both layers).

### `Login.jsx`

`handleEnter` only calls `navigate('/dashboard')`. **There is no authentication**: this is a demo landing
page. Say so if asked; it is listed as a limitation.

### `Orders.jsx` — the main workflow

Key state: `orderUserId`, `orderItems` (array of `{productId, quantity}`), `orderErrors`, `submitting`,
`isCreateModalOpen`, `isStatusModalOpen`, `orderToUpdate`, `newStatus`, filters `searchTerm`, `statusFilter`.

| Function | What it does |
|---|---|
| `handleOpenCreateModal` | pre-selects the first user and product, one line with quantity 1 |
| `handleAddItemRow` / `handleRemoveItemRow` | add a line / remove a line (never the last one) |
| `handleItemChange(index, field, value)` | immutable update of one line (`map` + spread) |
| `calculateOrderPreviewTotal` | price × quantity summed **for display only** — the backend computes the real total |
| `handleCreateOrder` | client validation (customer chosen; each line has a product; quantity ≥ 1; quantity ≤ current stock), then `ordersApi.create({ userId: Number(...), items: [{ productId: Number, quantity: parseInt }] })`, success toast, close modal, reload |
| `handleOpenStatusModal` / `handleUpdateStatus` | `ordersApi.updateStatus(id, newStatus)`; the Save button is **disabled when the order is already CANCELLED**; a warning explains that cancelling restores stock |
| `filteredOrders` | client-side filter by id/name/email text and status buttons |

Products with `stockQuantity <= 0` are disabled in the product dropdown. Client-side stock checks improve
the user experience but are **not trusted**: another user may buy the stock between page load and submit,
so the backend re-checks under a row lock.

### End-to-end trace: clicking **Confirm Order**

1. Browser: `handleCreateOrder` validates and calls `ordersApi.create(payload)`.
2. `request('/orders', {method:'POST', body: JSON.stringify(payload)})` → `fetch('/api/orders')` on the same
   origin, e.g. `http://k8s-orderinv-….elb.amazonaws.com/api/orders`.
3. On EKS the **ALB** matches the Ingress rule `path: /api, pathType: Prefix` and forwards to a **backend
   pod IP** in the backend target group (target type `ip`). In Docker Compose, **nginx** in the frontend
   container matches `location /api/` and proxies to `http://backend:8080` adding `X-Request-Id`.
4. Backend: `RequestIdFilter` sets the request id → `OrderController.createOrder` validates the DTO
   (`@Valid`) → `OrderService.createOrder` (one transaction): load user; lock each product row
   (`SELECT … FOR UPDATE`, ascending id); check stock; deduct; build `OrderItem`s with the current price;
   save order (cascade saves items) → commit.
5. Response `201 Created` with the `OrderResponse` JSON (id, user, total, status `PENDING`, items with
   subtotals) and header `X-Request-Id`.
6. Browser: `api.js` returns the parsed JSON → toast "Order created successfully" → modal closes →
   `fetchData()` reloads orders, users and products, so the new order and the reduced stock appear.

If step 4 fails with insufficient stock: 400 with the message → red toast with "Insufficient stock for
product …"; nothing was written (the transaction rolled back).

## 2.7 Production build and how the container serves it

`npm run build` → `dist/index.html` + `dist/assets/*-<hash>.js|css`. The Docker image copies `dist/` into
nginx's web root (`/usr/share/nginx/html`). nginx (`nginx/default.conf.template`, explained in
[05-docker.md](05-docker.md)) serves `/assets/` with a 1-year immutable cache (file names change on every
build), serves `index.html` with `Cache-Control: no-cache` (so a new deployment is picked up on the next page
load), answers `/healthz` itself for probes, and proxies `/api/` to the backend.

| Concern | Local dev (`npm run dev`) | Docker Compose | EKS |
|---|---|---|---|
| Who serves the UI | Vite dev server :5173 | nginx in `inventory-frontend` (host port 3000) | nginx in frontend pods behind the ALB |
| Who routes `/api` | Vite proxy → `localhost:8080` | nginx `location /api/` → `http://backend:8080` | the ALB Ingress rule → backend pods (nginx proxy exists but is not used for `/api` traffic from the ALB) |
| API base in JS | `/api` | `/api` | `/api` |
| Build-time vs runtime config | `VITE_*` at build time | nginx `BACKEND_URL` at container start (envsubst) | `BACKEND_URL` = `http://backend.order-inventory.svc.cluster.local:8080` from the Helm chart |

## 2.8 Frontend tests (21 tests, Vitest + Testing Library)

`src/test/setup.js` adds jest-dom matchers (`toBeInTheDocument`, …) and unmounts components after each test.
`src/test/helpers.js` provides `jsonResponse(body, status)` and `mockApi(routes)`, which replaces global `fetch`
with a router keyed by `"METHOD /path"`; **any unexpected request throws**, so a test cannot silently pass
while the page calls the wrong endpoint.

| File | Tests |
|---|---|
| `services/api.test.js` (7) | JSON success; JSON request bodies; 204 → null; validation `details` surfaced; fallback to message then status; 200 HTML treated as error; network failure mapped to the friendly message |
| `App.test.jsx` (5) | `/` → dashboard with live KPIs; dashboard error shown when the API fails; products table with stock badges; users and orders pages; unknown route → dashboard |
| `pages/workflows.test.jsx` (7) | products: client validation before calling the API; typed create payload + success; 409 message on delete. users: invalid email rejected and duplicate-email error shown. orders: quantity above stock blocked then valid order submitted; cancel a pending order; cancelled order cannot be changed |
| `hooks/useToasts.test.js` (2) | unique ids in the same millisecond + expiry; stable callbacks |

Frontend vs backend tests: the frontend tests run in jsdom with a **mocked** API and verify UI behaviour
(rendering, validation, which request is sent, how responses are displayed). The backend tests run the real
Spring context against a real (in-memory) database and verify business rules and HTTP semantics. Together
with the smoke test (real browser-less HTTP against the deployed system) they cover the whole path.

Result (from `docs/TESTING.md`): 21/21 passed, lines 80 %, branches 67 %, lint 0 errors/0 warnings, build OK —
VERIFIED, and re-run in every Jenkins build (#4, #7, #8).

## 2.9 Viva questions (frontend)

| Question | Answer based on this project |
|---|---|
| Why React? | Component model for a data-heavy admin UI, large ecosystem (React Router, Testing Library), and the team knew it. The app needs no server-side rendering. |
| Why Vite instead of Create React App? | CRA is no longer maintained; Vite starts instantly (native ES modules in dev), builds with Rollup into hashed assets, and integrates Vitest with the same config file. |
| Why a separate frontend container? | The UI is static files; nginx serves them efficiently, can be scaled and rolled out independently of the backend, and has its own health check (`/healthz`) and image/vulnerability scan. |
| How does the browser find the backend? | It doesn't need to: it calls the relative path `/api` on the host it loaded the page from; the ALB (EKS), nginx (Compose) or Vite proxy (dev) routes `/api` to the backend. |
| Build-time vs runtime configuration? | `VITE_API_BASE_URL` is baked into the JS at build time (same image everywhere, so it is left unset). nginx's `BACKEND_URL` is substituted when the container starts, so one image works in Compose and Kubernetes. |
| Why must API secrets not be in `VITE_*` variables? | They become part of the public JavaScript bundle. |
| What happens on 400/404/500/503? | See the table in §2.4: the backend's message (or field details) is shown in a toast; 503 means "database temporarily unavailable, retry"; 500 shows a generic message only. |
| What if the backend is down completely? | `fetch` throws a `TypeError` → "Unable to connect to backend server…"; the header badge shows "API Offline"; after 15 s without an answer: "The backend did not respond in time". |
| Why reload data after every change instead of updating state locally? | The server computes totals, stock and status; reloading guarantees the UI shows what was actually committed (e.g. stock after a concurrent order). |
| Is there authentication? | No. The login page only navigates. This is a documented limitation. |
