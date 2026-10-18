/**
 * Centralized API Service for Order & Inventory Management System
 * Uses standard Fetch API to interact with the Spring Boot backend.
 */

// Same-origin '/api' by default: nginx (Docker Compose), the ALB Ingress (EKS) and the
// Vite dev-server proxy all route it to the backend. Override at build time if needed.
export const API_BASE_URL = (import.meta.env.VITE_API_BASE_URL || '/api').replace(/\/+$/, '');

const REQUEST_TIMEOUT_MS = 15000;

/**
 * Generic request helper with error handling and response parsing
 */
export async function request(endpoint, options = {}) {
  const url = `${API_BASE_URL}${endpoint}`;

  const defaultHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  const config = {
    ...options,
    signal: controller.signal,
    headers: {
      ...defaultHeaders,
      ...options.headers,
    },
  };

  try {
    const response = await fetch(url, config);

    // Handle 204 No Content
    if (response.status === 204) {
      return null;
    }

    const isJson = (response.headers.get('content-type') || '').includes('application/json');
    const data = isJson ? await response.json().catch(() => null) : null;

    if (!response.ok) {
      const errorMessage = (data?.details && data.details.length ? data.details.join(', ') : data?.message) || `Request failed with status ${response.status}`;
      const error = new Error(errorMessage);
      error.status = response.status;
      error.data = data;
      throw error;
    }

    // A 2xx without a JSON body means /api was not routed to the backend
    // (e.g. an SPA fallback returned index.html). Treat it as a failure.
    if (!isJson) {
      const error = new Error('Unexpected response from API. Check that /api is routed to the backend service.');
      error.status = response.status;
      throw error;
    }

    return data;
  } catch (err) {
    if (err.name === 'AbortError') {
      throw new Error('The backend did not respond in time. Please try again.');
    }
    // fetch() rejects with a TypeError on network failures (message differs per browser)
    if (err instanceof TypeError) {
      throw new Error('Unable to connect to backend server. Please verify the Spring Boot service is running.');
    }
    throw err;
  } finally {
    clearTimeout(timeoutId);
  }
}

// ==========================================
// Health API
// ==========================================
export const healthApi = {
  getHealth: () => request('/health', { method: 'GET' }),
};

// ==========================================
// Users API
// ==========================================
export const usersApi = {
  getAll: () => request('/users', { method: 'GET' }),
  getById: (id) => request(`/users/${id}`, { method: 'GET' }),
  create: (userData) => request('/users', {
    method: 'POST',
    body: JSON.stringify(userData),
  }),
};

// ==========================================
// Products API
// ==========================================
export const productsApi = {
  getAll: () => request('/products', { method: 'GET' }),
  getById: (id) => request(`/products/${id}`, { method: 'GET' }),
  create: (productData) => request('/products', {
    method: 'POST',
    body: JSON.stringify(productData),
  }),
  update: (id, productData) => request(`/products/${id}`, {
    method: 'PUT',
    body: JSON.stringify(productData),
  }),
  delete: (id) => request(`/products/${id}`, { method: 'DELETE' }),
};

// ==========================================
// Orders API
// ==========================================
export const ordersApi = {
  getAll: () => request('/orders', { method: 'GET' }),
  getById: (id) => request(`/orders/${id}`, { method: 'GET' }),
  create: (orderData) => request('/orders', {
    method: 'POST',
    body: JSON.stringify(orderData),
  }),
  updateStatus: (id, status) => request(`/orders/${id}/status`, {
    method: 'PUT',
    body: JSON.stringify({ status }),
  }),
};
