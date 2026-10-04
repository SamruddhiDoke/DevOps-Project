/**
 * Centralized API Service for Order & Inventory Management System
 * Uses standard Fetch API to interact with the Spring Boot backend.
 */

export const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8080/api';

/**
 * Generic request helper with error handling and response parsing
 */
async function request(endpoint, options = {}) {
  const url = `${API_BASE_URL}${endpoint}`;
  
  const defaultHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  const config = {
    ...options,
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

    const data = await response.json().catch(() => null);

    if (!response.ok) {
      const errorMessage = data?.message || (data?.details && data.details.join(', ')) || `Request failed with status ${response.status}`;
      const error = new Error(errorMessage);
      error.status = response.status;
      error.data = data;
      throw error;
    }

    return data;
  } catch (err) {
    if (err.name === 'TypeError' && err.message.includes('fetch')) {
      throw new Error('Unable to connect to backend server. Please verify the Spring Boot service is running.');
    }
    throw err;
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
