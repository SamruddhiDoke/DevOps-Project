import { vi } from 'vitest';

export function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/**
 * Stubs global fetch with a router keyed by "METHOD /path" (path relative to /api).
 * Unmatched requests fail the test loudly instead of hanging.
 */
export function mockApi(routes) {
  const fetchMock = vi.fn(async (url, options = {}) => {
    const method = (options.method || 'GET').toUpperCase();
    const path = String(url).replace(/^\/api/, '');
    const handler = routes[`${method} ${path}`];
    if (!handler) {
      throw new Error(`Unexpected request in test: ${method} ${url}`);
    }
    return typeof handler === 'function' ? handler(options) : jsonResponse(handler);
  });
  vi.stubGlobal('fetch', fetchMock);
  return fetchMock;
}
