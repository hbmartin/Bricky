import {
  app,
  type HttpRequest,
  type HttpResponseInit,
  type InvocationContext,
} from '@azure/functions';
import { AdminAuth } from '../auth.js';
import { TableSupportStore, type SupportStore } from '../support.js';
import { ProxyError, type ErrorBody } from '../types.js';

/**
 * POST /api/inbox — tiny admin inbox for support inquiries. Body `{ action }`:
 *   status   → { configured }
 *   setup    → { password }            (first-time only) → { ok }
 *   login    → { password }            → { token }
 *   list     → { token }               → { inquiries: [...] }
 * No paid web app: this backs an Azure Storage static-website inbox page.
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

let store: SupportStore | undefined;
let auth: AdminAuth | undefined;
function deps() {
  const conn = env('SUPPORT_TABLE_CONNECTION') ?? requireEnv('QUOTA_TABLE_CONNECTION');
  if (!store) store = new TableSupportStore(conn);
  if (!auth) auth = new AdminAuth(conn, requireEnv('ADMIN_SECRET'));
  return { store, auth };
}

export async function inbox(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  if (request.method === 'OPTIONS') return { status: 204, headers: CORS };
  try {
    const body = (await request.json().catch(() => ({}))) as Record<string, string>;
    const { store, auth } = deps();
    switch (body.action) {
      case 'status':
        return { status: 200, headers: CORS, jsonBody: { configured: await auth.isConfigured() } };
      case 'setup':
        await auth.setPassword(body.password);
        return { status: 200, headers: CORS, jsonBody: { token: await auth.login(body.password) } };
      case 'login':
        return { status: 200, headers: CORS, jsonBody: { token: await auth.login(body.password) } };
      case 'list':
        auth.verify(body.token);
        return { status: 200, headers: CORS, jsonBody: { inquiries: await store.list() } };
      default:
        throw new ProxyError(400, 'bad_request', 'Unknown action.');
    }
  } catch (err) {
    if (err instanceof ProxyError) {
      const errorBody: ErrorBody = { error: err.message, code: err.code };
      return { status: err.status, headers: CORS, jsonBody: errorBody };
    }
    context.error('inbox unexpected error', err);
    return { status: 502, headers: CORS, jsonBody: { error: 'Inbox error.', code: 'upstream_error' } };
  }
}

app.http('inbox', { methods: ['POST', 'OPTIONS'], authLevel: 'anonymous', route: 'inbox', handler: inbox });
