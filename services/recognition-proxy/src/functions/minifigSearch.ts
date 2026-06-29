import {
  app,
  type HttpRequest,
  type HttpResponseInit,
  type InvocationContext,
} from '@azure/functions';
import { ProxyError, type ErrorBody } from '../types.js';

/**
 * GET /api/minifigSearch?q=blacktron
 *
 * Searches Rebrickable for minifigures by name using the server-side
 * `REBRICKABLE_API_KEY` (Key Vault secret `rebrickable-api-key`). Returns up to
 * 5 results as `{ results: [{ set_num, name }] }`. If the proxy has no key it
 * returns 503 `not_configured` and the app falls back to its bundled key. The
 * key never leaves the server.
 */

function env(name: string): string | undefined {
  const v = process.env[name];
  return v && v.length > 0 ? v : undefined;
}

function errorResponse(err: ProxyError): HttpResponseInit {
  const body: ErrorBody = { error: err.message, code: err.code };
  return { status: err.status, jsonBody: body };
}

interface MinifigResults {
  results: { set_num: string; name: string }[];
}

export async function minifigSearch(
  request: HttpRequest,
  context: InvocationContext,
): Promise<HttpResponseInit> {
  try {
    const apiKey = env('REBRICKABLE_API_KEY');
    if (!apiKey) {
      throw new ProxyError(503, 'not_configured', 'No server Rebrickable key.');
    }
    const q = request.query.get('q');
    if (!q) {
      throw new ProxyError(400, 'bad_request', 'Missing q query parameter.');
    }
    const url = `https://rebrickable.com/api/v3/lego/minifigs/?search=${encodeURIComponent(q)}&page_size=5`;
    const resp = await fetch(url, { headers: { Authorization: `key ${apiKey}` } });
    if (resp.status === 401 || resp.status === 403) {
      throw new ProxyError(502, 'upstream_error', 'Rebrickable rejected the key.');
    }
    if (!resp.ok) {
      throw new ProxyError(502, 'upstream_error', `Rebrickable error ${resp.status}.`);
    }
    const page = (await resp.json()) as MinifigResults;
    const results = (page.results ?? []).map((r) => ({ set_num: r.set_num, name: r.name }));
    return { status: 200, jsonBody: { results } };
  } catch (err) {
    if (err instanceof ProxyError) {
      context.warn(`minifigSearch ${err.code}: ${err.message}`);
      return errorResponse(err);
    }
    context.error('minifigSearch unexpected error', err);
    return errorResponse(new ProxyError(502, 'upstream_error', 'Minifig search failed.'));
  }
}

app.http('minifigSearch', {
  methods: ['GET'],
  authLevel: 'anonymous',
  route: 'minifigSearch',
  handler: minifigSearch,
});
