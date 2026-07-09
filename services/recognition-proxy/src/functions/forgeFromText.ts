import {
  app,
  type HttpRequest,
  type HttpResponseInit,
  type InvocationContext,
} from '@azure/functions';
import { verifyDevBypassToken } from '../entitlement.js';
import { forgeModelFromText } from '../forge.js';
import { type OpenAIConfig } from '../openai.js';
import { TableQuotaStore, type QuotaStore } from '../quota.js';
import {
  FORGE_SIZES,
  ProxyError,
  type ErrorBody,
  type ForgeModelResult,
  type ForgeSize,
  type ForgeTextRequest,
} from '../types.js';

/**
 * POST /api/forgeFromText
 *
 * Entitlement → quota → Azure OpenAI (GPT-4o) voxel authoring. Returns a
 * `ForgeModelResult` (expanded voxels) or an honest `{ error, code }` body. The
 * Azure OpenAI key never leaves the server. Cloud forging is a hidden,
 * developer-only feature gated by the developer-bypass token, exactly like
 * `recognizeImage` / `identifySet`.
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

export async function forgeFromText(
  request: HttpRequest,
  context: InvocationContext,
): Promise<HttpResponseInit> {
  try {
    // --- parse body ---
    let body: ForgeTextRequest;
    try {
      body = (await request.json()) as ForgeTextRequest;
    } catch {
      throw new ProxyError(400, 'bad_request', 'Invalid JSON body.');
    }
    const prompt = typeof body?.prompt === 'string' ? body.prompt.trim() : '';
    if (prompt.length < 2) {
      throw new ProxyError(400, 'bad_request', 'Missing or too-short prompt.');
    }
    if (prompt.length > 300) {
      throw new ProxyError(400, 'bad_request', 'Prompt is too long.');
    }
    const size: ForgeSize = FORGE_SIZES.includes(body?.size as ForgeSize)
      ? (body.size as ForgeSize)
      : 'medium';

    // --- verify entitlement (developer-only) ---
    const entitlement = verifyDevBypassToken(
      body.entitlementToken,
      env('DEV_BYPASS_TOKEN'),
    );
    if (!entitlement) {
      throw new ProxyError(403, 'not_entitled', 'Cloud model generation is not available.');
    }

    // --- enforce monthly quota server-side ---
    const { remaining } = await quotaStore().consume(entitlement.userKey);

    // --- call Azure OpenAI ---
    const config: OpenAIConfig = {
      endpoint: requireEnv('AZURE_OPENAI_ENDPOINT'),
      apiKey: requireEnv('AZURE_OPENAI_API_KEY'),
      deployment: requireEnv('AZURE_OPENAI_DEPLOYMENT'),
      apiVersion: requireEnv('AZURE_OPENAI_API_VERSION'),
    };
    const grid = await forgeModelFromText(prompt, size, config);

    if (grid.voxels.length === 0) {
      throw new ProxyError(
        422,
        'upstream_error',
        "Couldn't design a model for that description. Try describing it differently.",
      );
    }

    const result: ForgeModelResult = {
      width: grid.width,
      height: grid.height,
      depth: grid.depth,
      voxels: grid.voxels,
      subject: prompt,
      remainingQuota: remaining,
    };
    return { status: 200, jsonBody: result };
  } catch (err) {
    if (err instanceof ProxyError) {
      context.warn(`forgeFromText ${err.code}: ${err.message}`);
      return errorResponse(err);
    }
    context.error('forgeFromText unexpected error', err);
    return errorResponse(new ProxyError(502, 'upstream_error', 'Model generation failed.'));
  }
}

app.http('forgeFromText', {
  methods: ['POST'],
  authLevel: 'anonymous',
  route: 'forgeFromText',
  handler: forgeFromText,
});
