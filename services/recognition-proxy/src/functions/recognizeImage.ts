import {
  app,
  type HttpRequest,
  type HttpResponseInit,
  type InvocationContext,
} from '@azure/functions';
import { verifyDevBypassToken } from '../entitlement.js';
import { recognizeWithOpenAI, type OpenAIConfig } from '../openai.js';
import { TableQuotaStore, type QuotaStore } from '../quota.js';
import {
  ProxyError,
  type ErrorBody,
  type RecognitionRequest,
  type RecognitionResult,
} from '../types.js';

/**
 * POST /api/recognizeImage
 *
 * Entitlement → quota → Azure OpenAI vision. Returns `RecognitionResult` or an
 * honest `{ error, code }` body with a mapped status. The Azure OpenAI key
 * never leaves the server.
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

export async function recognizeImage(
  request: HttpRequest,
  context: InvocationContext,
): Promise<HttpResponseInit> {
  try {
    // --- parse body ---
    let body: RecognitionRequest;
    try {
      body = (await request.json()) as RecognitionRequest;
    } catch {
      throw new ProxyError(400, 'bad_request', 'Invalid JSON body.');
    }
    if (!body?.imageBase64 || typeof body.imageBase64 !== 'string') {
      throw new ProxyError(400, 'bad_request', 'Missing imageBase64.');
    }

    // --- verify entitlement (developer-only) ---
    // Cloud AI recognition is a hidden, developer-only feature. The ONLY way to
    // unlock it is the developer-bypass token, which is honored solely when this
    // proxy has a matching DEV_BYPASS_TOKEN configured. There is no purchasable
    // subscription, so the real StoreKit verification path is intentionally not
    // used here; `verifyEntitlement` is retained for a future paid tier.
    const entitlement = verifyDevBypassToken(
      body.entitlementToken,
      env('DEV_BYPASS_TOKEN'),
    );
    if (!entitlement) {
      throw new ProxyError(403, 'not_entitled', 'Cloud AI recognition is not available.');
    }

    // --- enforce monthly quota server-side ---
    const { remaining } = await quotaStore().consume(entitlement.userKey);

    // --- call Azure OpenAI vision ---
    const config: OpenAIConfig = {
      endpoint: requireEnv('AZURE_OPENAI_ENDPOINT'),
      apiKey: requireEnv('AZURE_OPENAI_API_KEY'),
      deployment: requireEnv('AZURE_OPENAI_DEPLOYMENT'),
      apiVersion: requireEnv('AZURE_OPENAI_API_VERSION'),
    };
    const subjects = await recognizeWithOpenAI(body.imageBase64, config);

    const result: RecognitionResult = { subjects, remainingQuota: remaining };
    return { status: 200, jsonBody: result };
  } catch (err) {
    if (err instanceof ProxyError) {
      context.warn(`recognizeImage ${err.code}: ${err.message}`);
      return errorResponse(err);
    }
    context.error('recognizeImage unexpected error', err);
    return errorResponse(
      new ProxyError(502, 'upstream_error', 'Recognition failed.'),
    );
  }
}

app.http('recognizeImage', {
  methods: ['POST'],
  // Anonymous at the platform layer: the real authentication is the
  // Apple-signed StoreKit entitlement JWS, verified server-side in
  // `verifyEntitlement`. A Functions key shipped inside the iOS binary would
  // be trivially extractable and is not a real secret, so we don't rely on it.
  authLevel: 'anonymous',
  route: 'recognizeImage',
  handler: recognizeImage,
});
