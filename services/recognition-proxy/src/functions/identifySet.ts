import {
  app,
  type HttpRequest,
  type HttpResponseInit,
  type InvocationContext,
} from '@azure/functions';
import { verifyDevBypassToken } from '../entitlement.js';
import { identifySetWithOpenAI, type OpenAIConfig } from '../openai.js';
import { TableQuotaStore, type QuotaStore } from '../quota.js';
import {
  ProxyError,
  type ErrorBody,
  type SetIdentificationRequest,
  type SetIdentificationResult,
} from '../types.js';

/**
 * POST /api/identifySet
 *
 * Entitlement → quota → Azure OpenAI vision. Identifies which official LEGO set
 * an already-built model in a photo is and returns up to 3 candidates, or an
 * honest `{ error, code }` body with a mapped status. The Azure OpenAI key
 * never leaves the server.
 *
 * Like `recognizeImage`, this is a hidden, developer-only feature: the only way
 * to unlock it is the developer-bypass token, honored solely when this proxy has
 * a matching `DEV_BYPASS_TOKEN` configured. Set identification shares the same
 * per-user monthly quota as subject recognition (both are GPT-4o vision calls).
 */

function env(name: string): string | undefined {
  const v = process.env[name];
  return v && v.length > 0 ? v : undefined;
}

function requireEnv(name: string): string {
  const v = env(name);
  if (!v) {
    throw new ProxyError(503, 'not_configured', `Missing configuration: ${name}.`);
  }
  return v;
}

function errorResponse(err: ProxyError): HttpResponseInit {
  const body: ErrorBody = { error: err.message, code: err.code };
  return { status: err.status, jsonBody: body };
}

let cachedQuota: QuotaStore | undefined;
function quotaStore(): QuotaStore {
  if (!cachedQuota) {
    cachedQuota = new TableQuotaStore(
      requireEnv('QUOTA_TABLE_CONNECTION'),
      Number(env('MONTHLY_QUOTA') ?? '100'),
    );
  }
  return cachedQuota;
}

export async function identifySet(
  request: HttpRequest,
  context: InvocationContext,
): Promise<HttpResponseInit> {
  try {
    // --- parse body ---
    let body: SetIdentificationRequest;
    try {
      body = (await request.json()) as SetIdentificationRequest;
    } catch {
      throw new ProxyError(400, 'bad_request', 'Invalid JSON body.');
    }
    if (!body?.imageBase64 || typeof body.imageBase64 !== 'string') {
      throw new ProxyError(400, 'bad_request', 'Missing imageBase64.');
    }

    // --- verify entitlement (developer-only) ---
    const entitlement = verifyDevBypassToken(
      body.entitlementToken,
      env('DEV_BYPASS_TOKEN'),
    );
    if (!entitlement) {
      throw new ProxyError(403, 'not_entitled', 'Set identification is not available.');
    }

    // --- enforce monthly quota server-side (shared with recognizeImage) ---
    const { remaining } = await quotaStore().consume(entitlement.userKey);

    // --- call Azure OpenAI vision ---
    const config: OpenAIConfig = {
      endpoint: requireEnv('AZURE_OPENAI_ENDPOINT'),
      apiKey: requireEnv('AZURE_OPENAI_API_KEY'),
      deployment: requireEnv('AZURE_OPENAI_DEPLOYMENT'),
      apiVersion: requireEnv('AZURE_OPENAI_API_VERSION'),
    };
    const candidates = await identifySetWithOpenAI(body.imageBase64, config);

    const result: SetIdentificationResult = { candidates, remainingQuota: remaining };
    return { status: 200, jsonBody: result };
  } catch (err) {
    if (err instanceof ProxyError) {
      context.warn(`identifySet ${err.code}: ${err.message}`);
      return errorResponse(err);
    }
    context.error('identifySet unexpected error', err);
    return errorResponse(
      new ProxyError(502, 'upstream_error', 'Set identification failed.'),
    );
  }
}

app.http('identifySet', {
  methods: ['POST'],
  // Anonymous at the platform layer: the real authentication is the
  // developer-bypass token, verified server-side in `verifyDevBypassToken`.
  authLevel: 'anonymous',
  route: 'identifySet',
  handler: identifySet,
});
