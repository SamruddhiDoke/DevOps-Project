import { describe, it, expect, afterEach, vi } from 'vitest';
import { render, screen, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import App from './App';
import { mockApi } from './test/helpers';

const users = [{ id: 1, name: 'Alex Morgan', email: 'alex.morgan@example.com', phone: null, createdAt: '2026-09-01T10:00:00' }];
const products = [
  { id: 1, name: 'ProBook Laptop', description: 'i7', price: 1199.99, stockQuantity: 25, category: 'Electronics', status: 'IN_STOCK' },
  { id: 2, name: 'Ergonomic Mouse', description: null, price: 49.99, stockQuantity: 4, category: 'Accessories', status: 'LOW_STOCK' },
];
const orders = [{
  id: 11, userId: 1, userName: 'Alex Morgan', userEmail: 'alex.morgan@example.com',
  totalAmount: 1249.98, status: 'PENDING', createdAt: '2026-10-01T10:00:00',
  items: [{ id: 1, productId: 1, productName: 'ProBook Laptop', quantity: 1, price: 1199.99, subtotal: 1199.99 }],
}];

function renderAt(path) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <App />
    </MemoryRouter>
  );
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('App routing and pages', () => {
  it('redirects / to the dashboard and shows live KPIs from the API', async () => {
    mockApi({
      'GET /health': { status: 'UP' },
      'GET /users': users,
      'GET /products': products,
      'GET /orders': orders,
    });

    renderAt('/');

    expect(await screen.findByRole('heading', { name: 'Operations Dashboard' })).toBeInTheDocument();
    expect(await screen.findByText('#11')).toBeInTheDocument();
    expect(screen.getByText('API Online')).toBeInTheDocument();
    // Low-stock card lists the product with <= 10 units
    expect(screen.getByText('Ergonomic Mouse')).toBeInTheDocument();
  });

  it('shows an error on the dashboard instead of silently empty data when the API fails', async () => {
    mockApi({
      'GET /health': () => new Response(null, { status: 503 }),
      'GET /users': users,
      'GET /products': () => new Response(JSON.stringify({ message: 'Database unavailable' }), { status: 500, headers: { 'Content-Type': 'application/json' } }),
      'GET /orders': orders,
    });

    renderAt('/dashboard');

    expect(await screen.findByText(/Failed to fetch dashboard data: Database unavailable/)).toBeInTheDocument();
    expect(await screen.findByText('API Offline')).toBeInTheDocument();
  });

  it('renders the products table with stock status badges', async () => {
    mockApi({
      'GET /health': { status: 'UP' },
      'GET /products': products,
    });

    renderAt('/products');

    const row = (await screen.findByText('Ergonomic Mouse')).closest('tr');
    expect(within(row).getByText('$49.99')).toBeInTheDocument();
    expect(within(row).getByText(/Low Stock/)).toBeInTheDocument();
  });

  it('renders users and orders pages from backend data', async () => {
    mockApi({
      'GET /health': { status: 'UP' },
      'GET /users': users,
      'GET /products': products,
      'GET /orders': orders,
    });

    const { unmount } = renderAt('/users');
    expect(await screen.findByText('alex.morgan@example.com')).toBeInTheDocument();
    unmount();

    renderAt('/orders');
    expect(await screen.findByText('$1249.98')).toBeInTheDocument();
  });

  it('falls back to the dashboard for unknown routes', async () => {
    mockApi({
      'GET /health': { status: 'UP' },
      'GET /users': [],
      'GET /products': [],
      'GET /orders': [],
    });

    renderAt('/does-not-exist');
    expect(await screen.findByRole('heading', { name: 'Operations Dashboard' })).toBeInTheDocument();
    expect(await screen.findByText('No orders yet')).toBeInTheDocument();
  });
});
