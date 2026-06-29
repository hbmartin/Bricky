import {
  app,
  type HttpRequest,
  type HttpResponseInit,
  type InvocationContext,
} from '@azure/functions';
import { ProxyError, type ErrorBody } from '../types.js';

/**
 * GET /api/setParts?set=60431
 *
 * Returns the full bill of materials for a LEGO set from Rebrickable, using the
 * server-side `REBRICKABLE_API_KEY` (a Key Vault reference to the secret named
 * `rebrickable-api-key`). The app checks this first; if the proxy has no key it
 * returns 503 `not_configured` and the app falls back to a user-supplied key.
 * Spares are excluded; quantities for the same part+color are summed. The key
 * never leaves the server.
 */

function env(name: string): string | undefined {
  const v = process.env[name];
  return v && v.length > 0 ? v : undefined;
}

function errorResponse(err: ProxyError): HttpResponseInit {
  const body: ErrorBody = { error: err.message, code: err.code };
  return { status: err.status, jsonBody: body };
}

interface RebrickableRow {
  quantity: number;
  is_spare: boolean;
  part: { part_num: string };
  color: { name: string };
}
interface RebrickablePage {
  next: string | null;
  results: RebrickableRow[];
}

export async function setParts(
  request: HttpRequest,
  context: InvocationContext,
): Promise<HttpResponseInit> {
  try {
    const apiKey = env('REBRICKABLE_API_KEY');
    if (!apiKey) {
      throw new ProxyError(503, 'not_configured', 'No server Rebrickable key.');
    }
    const raw = request.query.get('set');
    if (!raw) {
      throw new ProxyError(400, 'bad_request', 'Missing set query parameter.');
    }
    const base = raw.includes('-') ? raw.slice(0, raw.indexOf('-')) : raw;
    if (!/^[0-9A-Za-z]+$/.test(base)) {
      throw new ProxyError(400, 'bad_request', 'Invalid set number.');
    }

    const combined = new Map<string, { partNumber: string; color: string; quantity: number }>();
    let url: string | null =
      `https://rebrickable.com/api/v3/lego/sets/${base}-1/parts/?page_size=1000`;
    while (url) {
      const resp = await fetch(url, { headers: { Authorization: `key ${apiKey}` } });
      if (resp.status === 401 || resp.status === 403) {
        throw new ProxyError(502, 'upstream_error', 'Rebrickable rejected the key.');
      }
      if (resp.status === 404) {
        throw new ProxyError(404, 'not_found', 'No parts list for this set.');
      }
      if (!resp.ok) {
        throw new ProxyError(502, 'upstream_error', `Rebrickable error ${resp.status}.`);
      }
      const page = (await resp.json()) as RebrickablePage;
      for (const row of page.results) {
        if (row.is_spare) continue;
        const color = row.color.name;
        const key = `${row.part.part_num}|${color}`;
        const existing = combined.get(key);
        combined.set(key, {
          partNumber: row.part.part_num,
          color,
          quantity: (existing?.quantity ?? 0) + row.quantity,
        });
      }
      url = page.next;
    }
    return { status: 200, jsonBody: { pieces: Array.from(combined.values()) } };
  } catch (err) {
    if (err instanceof ProxyError) {
      context.warn(`setParts ${err.code}: ${err.message}`);
      return errorResponse(err);
    }
    context.error('setParts unexpected error', err);
    return errorResponse(new ProxyError(502, 'upstream_error', 'Set parts fetch failed.'));
  }
}

app.http('setParts', {
  methods: ['GET'],
  authLevel: 'anonymous',
  route: 'setParts',
  handler: setParts,
});
