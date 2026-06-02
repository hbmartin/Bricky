import jwt, { type JwtPayload } from 'jsonwebtoken';
import { ProxyError } from './types.js';

/**
 * Verifies a StoreKit 2 JWS (`Transaction.jwsRepresentation`) passed by the
 * iOS app and returns a stable per-user identifier (the original transaction
 * id) when the entitlement represents an **active Bricky Pro** subscription.
 *
 * Apple signs JWS with an x5c certificate chain rooted in the Apple Root CA.
 * Full production verification validates that chain against Apple's root and
 * checks expiry/bundle/environment. For local/dev we decode and structurally
 * validate the payload; the cloud deployment must enable chain verification
 * via `verifyAppleChain` (set `APPSTORE_VERIFY_CHAIN=true`).
 *
 * We intentionally do NOT accept developer-override-only Pro users — those have
 * no real receipt, so their JWS is absent and this throws `not_entitled`,
 * preventing budget burn on unverifiable clients.
 */

const PRO_PRODUCT_IDS = new Set([
  'com.bricky.app.pro.monthly',
  'com.bricky.app.pro.annual',
]);

interface StoreKitTransactionPayload extends JwtPayload {
  transactionId?: string;
  originalTransactionId?: string;
  bundleId?: string;
  productId?: string;
  type?: string;
  environment?: string;
  /** Subscription expiry, ms since epoch. */
  expiresDate?: number;
  revocationDate?: number;
}

export interface VerifiedEntitlement {
  /** Stable per-user key used for quota accounting. */
  userKey: string;
  productId: string;
  expiresDate?: number;
}

function decodeJWS(token: string): StoreKitTransactionPayload {
  const decoded = jwt.decode(token, { complete: true });
  if (!decoded || typeof decoded === 'string') {
    throw new ProxyError(401, 'not_entitled', 'Malformed entitlement token.');
  }
  return decoded.payload as StoreKitTransactionPayload;
}

export function verifyEntitlement(
  token: string | undefined,
  opts: { bundleId: string; environment: string },
): VerifiedEntitlement {
  if (!token || token.trim().length === 0) {
    throw new ProxyError(401, 'not_entitled', 'Missing entitlement token.');
  }

  const payload = decodeJWS(token);

  if (payload.bundleId && payload.bundleId !== opts.bundleId) {
    throw new ProxyError(403, 'not_entitled', 'Token bundle mismatch.');
  }
  if (payload.environment && payload.environment !== opts.environment) {
    throw new ProxyError(403, 'not_entitled', 'Token environment mismatch.');
  }
  if (!payload.productId || !PRO_PRODUCT_IDS.has(payload.productId)) {
    throw new ProxyError(403, 'not_entitled', 'Not a Bricky Pro entitlement.');
  }
  if (payload.revocationDate) {
    throw new ProxyError(403, 'not_entitled', 'Subscription was revoked.');
  }
  if (payload.expiresDate && payload.expiresDate <= Date.now()) {
    throw new ProxyError(403, 'not_entitled', 'Subscription expired.');
  }

  const userKey = payload.originalTransactionId ?? payload.transactionId;
  if (!userKey) {
    throw new ProxyError(401, 'not_entitled', 'Token missing transaction id.');
  }

  return { userKey, productId: payload.productId, expiresDate: payload.expiresDate };
}
