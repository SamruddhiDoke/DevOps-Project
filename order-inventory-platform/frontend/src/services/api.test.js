import { describe, it, expect, vi, afterEach } from 'vitest';
import { productsApi, usersApi, healthApi } from './api';
import { jsonResponse } from '../test/helpers';

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('api service', () => {
  it('returns parsed JSON for successful requests against /api', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ status: 'UP' }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(healthApi.getHealth()).resolves.toEqual({ status: 'UP' });
    expect(fetchMock).toHaveBeenCalledWith('/api/health', expect.objectContaining({ method: 'GET' }));
  });

  it('sends JSON bodies for create requests', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ id: 7 }, 201));
    vi.stubGlobal('fetch', fetchMock);

    await usersApi.create({ name: 'Jane', email: 'jane@example.com' });
    const [, options] = fetchMock.mock.calls[0];
    expect(options.method).toBe('POST');
    expect(JSON.parse(options.body)).toEqual({ name: 'Jane', email: 'jane@example.com' });
  });

  it('returns null for 204 No Content', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(null, { status: 204 })));
    await expect(productsApi.delete(1)).resolves.toBeNull();
  });

  it('surfaces validation details from backend error responses', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse({
      status: 400,
      message: 'Input validation failed for one or more fields',
      details: ['price: Price must be greater than 0'],
    }, 400)));

    await expect(productsApi.create({})).rejects.toMatchObject({
      message: 'price: Price must be greater than 0',
      status: 400,
    });
  });

  it('falls back to the backend message, then to the status code', async () => {
    vi.stubGlobal('fetch', vi.fn()
      .mockResolvedValueOnce(jsonResponse({ message: 'Product not found with id: 9' }, 404))
      .mockResolvedValueOnce(new Response('<html>Bad Gateway</html>', { status: 502, headers: { 'Content-Type': 'text/html' } })));

    await expect(productsApi.getById(9)).rejects.toThrow('Product not found with id: 9');
    await expect(productsApi.getById(9)).rejects.toThrow('Request failed with status 502');
  });

  it('treats a 200 HTML response (unrouted /api SPA fallback) as an error', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response('<!doctype html><html></html>', { status: 200, headers: { 'Content-Type': 'text/html' } })
    ));

    await expect(productsApi.getAll()).rejects.toThrow(/Unexpected response from API/);
  });

  it('maps network failures to a friendly message regardless of browser wording', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Load failed')));
    await expect(productsApi.getAll()).rejects.toThrow(/Unable to connect to backend server/);
  });
});
