import { describe, it, expect, afterEach, vi } from 'vitest';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import App from '../App';
import { mockApi, jsonResponse } from '../test/helpers';

const users = [{ id: 1, name: 'Alex Morgan', email: 'alex@example.com', phone: null, createdAt: '2026-09-01T10:00:00' }];
const products = [
  { id: 1, name: 'Laptop', description: null, price: 1000, stockQuantity: 5, category: 'Electronics', status: 'LOW_STOCK' },
  { id: 2, name: 'Headset', description: null, price: 100, stockQuantity: 0, category: 'Audio', status: 'OUT_OF_STOCK' },
];
const pendingOrder = {
  id: 7, userId: 1, userName: 'Alex Morgan', userEmail: 'alex@example.com', totalAmount: 1000,
  status: 'PENDING', createdAt: '2026-10-01T10:00:00',
  items: [{ id: 1, productId: 1, productName: 'Laptop', quantity: 1, price: 1000, subtotal: 1000 }],
};

function renderAt(path) {
  return render(<MemoryRouter initialEntries={[path]}><App /></MemoryRouter>);
}

function bodyOf(fetchMock, method, path) {
  const call = fetchMock.mock.calls.find(([url, opts]) => url === `/api${path}` && (opts?.method || 'GET') === method);
  return call ? JSON.parse(call[1].body) : undefined;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('Products workflow', () => {
  it('validates the form client-side before calling the API', async () => {
    const fetchMock = mockApi({ 'GET /health': { status: 'UP' }, 'GET /products': products });
    renderAt('/products');
    await screen.findByText('Laptop');

    fireEvent.click(screen.getByRole('button', { name: /Add Product/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Create Product' }));

    expect(screen.getByText('Product name is required')).toBeInTheDocument();
    expect(screen.getByText(/Valid price greater than 0/)).toBeInTheDocument();
    expect(fetchMock.mock.calls.some(([, o]) => o?.method === 'POST')).toBe(false);
  });

  it('creates a product with a typed payload and shows success', async () => {
    const fetchMock = mockApi({
      'GET /health': { status: 'UP' },
      'GET /products': products,
      'POST /products': () => jsonResponse({ id: 3 }, 201),
    });
    renderAt('/products');
    await screen.findByText('Laptop');

    fireEvent.click(screen.getByRole('button', { name: /Add Product/ }));
    const dialog = screen.getByRole('heading', { name: 'Add New Product' }).closest('.modal-content');
    fireEvent.change(within(dialog).getByPlaceholderText('e.g. Ergonomic Office Desk'), { target: { value: '  Desk  ' } });
    fireEvent.change(within(dialog).getByPlaceholderText('0.00'), { target: { value: '199.5' } });
    fireEvent.change(within(dialog).getByPlaceholderText('0'), { target: { value: '12' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Create Product' }));

    expect(await screen.findByText('Product created successfully')).toBeInTheDocument();
    expect(bodyOf(fetchMock, 'POST', '/products')).toEqual({
      name: 'Desk', description: null, price: 199.5, stockQuantity: 12, category: null,
    });
  });

  it('shows the backend message when deletion is refused (409)', async () => {
    mockApi({
      'GET /health': { status: 'UP' },
      'GET /products': products,
      'DELETE /products/1': () => jsonResponse({ status: 409, message: 'The request conflicts with existing data' }, 409),
    });
    renderAt('/products');
    const row = (await screen.findByText('Laptop')).closest('tr');

    fireEvent.click(within(row).getByTitle('Delete Product'));
    const confirm = screen.getByRole('heading', { name: 'Delete Product' }).closest('.modal-content');
    fireEvent.click(within(confirm).getByRole('button', { name: 'Delete Product' }));

    expect(await screen.findByText('The request conflicts with existing data')).toBeInTheDocument();
  });
});

describe('Users workflow', () => {
  it('rejects an invalid email and surfaces duplicate-email errors from the API', async () => {
    const fetchMock = mockApi({
      'GET /health': { status: 'UP' },
      'GET /users': users,
      'POST /users': () => jsonResponse({ status: 400, message: 'Email is already registered: alex@example.com' }, 400),
    });
    renderAt('/users');
    await screen.findByText('alex@example.com');

    fireEvent.click(screen.getByRole('button', { name: /Add User/ }));
    fireEvent.change(screen.getByPlaceholderText('e.g. Jane Smith'), { target: { value: 'Alex' } });
    const email = screen.getByPlaceholderText('e.g. jane.smith@example.com');

    // Native browser validation (type="email") blocks obviously malformed input...
    fireEvent.change(email, { target: { value: 'not-an-email' } });
    expect(email).toBeInvalid();

    // ...and the app rule additionally requires a domain with a dot
    fireEvent.change(email, { target: { value: 'alex@localhost' } });
    expect(email).toBeValid();
    fireEvent.click(screen.getByRole('button', { name: 'Create User' }));
    expect(screen.getByText('Please provide a valid email address')).toBeInTheDocument();
    expect(fetchMock.mock.calls.some(([, o]) => o?.method === 'POST')).toBe(false);

    fireEvent.change(screen.getByPlaceholderText('e.g. jane.smith@example.com'), { target: { value: 'ALEX@example.com' } });
    fireEvent.click(screen.getByRole('button', { name: 'Create User' }));

    expect(await screen.findByText('Email is already registered: alex@example.com')).toBeInTheDocument();
    expect(bodyOf(fetchMock, 'POST', '/users').email).toBe('alex@example.com');
  });
});

describe('Orders workflow', () => {
  const orderRoutes = (extra = {}) => ({
    'GET /health': { status: 'UP' },
    'GET /orders': [pendingOrder],
    'GET /users': users,
    'GET /products': products,
    ...extra,
  });

  it('blocks quantities above available stock and submits a valid order', async () => {
    const fetchMock = mockApi(orderRoutes({ 'POST /orders': () => jsonResponse({ id: 8 }, 201) }));
    renderAt('/orders');
    await screen.findByText('#7');

    fireEvent.click(screen.getByRole('button', { name: /Create Order/ }));
    const dialog = screen.getByRole('heading', { name: 'Create New Customer Order' }).closest('.modal-content');
    const qty = within(dialog).getByPlaceholderText('Qty');

    // max={stock} makes the browser refuse quantities above the available stock
    fireEvent.change(qty, { target: { value: '6' } });
    expect(qty).toBeInvalid();
    fireEvent.click(within(dialog).getByRole('button', { name: 'Confirm Order' }));
    expect(fetchMock.mock.calls.some(([, o]) => o?.method === 'POST')).toBe(false);

    fireEvent.change(qty, { target: { value: '2' } });
    expect(within(dialog).getByText('$2000.00', { selector: 'span' })).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole('button', { name: 'Confirm Order' }));

    expect(await screen.findByText('Order created successfully')).toBeInTheDocument();
    expect(bodyOf(fetchMock, 'POST', '/orders')).toEqual({ userId: 1, items: [{ productId: 1, quantity: 2 }] });
  });

  it('cancels a pending order', async () => {
    const fetchMock = mockApi(orderRoutes({
      'PUT /orders/7/status': () => jsonResponse({ ...pendingOrder, status: 'CANCELLED' }),
    }));
    renderAt('/orders');
    const row = (await screen.findByText('#7')).closest('tr');

    fireEvent.click(within(row).getByTitle('Update Status'));
    fireEvent.change(screen.getByDisplayValue('PENDING'), { target: { value: 'CANCELLED' } });
    expect(screen.getByText(/replenish warehouse inventory/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Update Status' }));

    expect(await screen.findByText('Order #7 updated to CANCELLED')).toBeInTheDocument();
    expect(bodyOf(fetchMock, 'PUT', '/orders/7/status')).toEqual({ status: 'CANCELLED' });
  });

  it('does not allow changing a cancelled order', async () => {
    mockApi({ ...orderRoutes(), 'GET /orders': [{ ...pendingOrder, status: 'CANCELLED' }] });
    renderAt('/orders');
    const row = (await screen.findByText('#7')).closest('tr');

    fireEvent.click(within(row).getByTitle('Update Status'));

    expect(screen.getByText(/Cancelled orders are final/)).toBeInTheDocument();
    await waitFor(() => expect(screen.getByRole('button', { name: 'Update Status' })).toBeDisabled());
  });
});
