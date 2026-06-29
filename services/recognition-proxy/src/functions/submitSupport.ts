import {
  app,
  type HttpRequest,
  type HttpResponseInit,
  type InvocationContext,
} from '@azure/functions';
import { TableSupportStore, validateInquiry, type SupportStore } from '../support.js';
import { ProxyError, type ErrorBody, type SupportInquiry } from '../types.js';

/**
 * POST /api/submitSupport
 *
 * Public contact form on the marketing site. Validates a small JSON inquiry
 * (email + message, honeypot, topic) and stores it in Azure Table Storage. No
 * auth — it's a public form — but inputs are validated, length-capped, and a
 * honeypot blocks trivial bots. Returns 200 `{ ok: true }` or `{ error, code }`.
 */

function env(name: string): string | undefined {
  const v = process.env[name];
  return v && v.length > 0 ? v : undefined;
}

function requireEnv(name: string): string {
  const v = env(name);
  if (!v) throw new ProxyError(503, 'not_configured', `Missing configuration: ${name}.`);
  return v;
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

let cachedStore: SupportStore | undefined;
function supportStore(): SupportStore {
  if (!cachedStore) {
    cachedStore = new TableSupportStore(
      env('SUPPORT_TABLE_CONNECTION') ?? requireEnv('QUOTA_TABLE_CONNECTION'),
    );
  }
  return cachedStore;
}

export async function submitSupport(
  request: HttpRequest,
  context: InvocationContext,
): Promise<HttpResponseInit> {
  if (request.method === 'OPTIONS') {
    return { status: 204, headers: CORS };
  }
  try {
    let body: SupportInquiry;
    try {
      body = (await request.json()) as SupportInquiry;
    } catch {
      throw new ProxyError(400, 'bad_request', 'Invalid JSON body.');
    }
    const inquiry = validateInquiry(body);
    await supportStore().save(inquiry);
    return { status: 200, headers: CORS, jsonBody: { ok: true } };
  } catch (err) {
    if (err instanceof ProxyError) {
      context.warn(`submitSupport ${err.code}: ${err.message}`);
      const errorBody: ErrorBody = { error: err.message, code: err.code };
      return { status: err.status, headers: CORS, jsonBody: errorBody };
    }
    context.error('submitSupport unexpected error', err);
    return {
      status: 502,
      headers: CORS,
      jsonBody: { error: 'Could not submit your message.', code: 'upstream_error' },
    };
  }
}

app.http('submitSupport', {
  methods: ['POST', 'OPTIONS'],
  authLevel: 'anonymous',
  route: 'submitSupport',
  handler: submitSupport,
});
