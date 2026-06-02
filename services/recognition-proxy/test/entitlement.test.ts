import { test } from 'node:test';
import assert from 'node:assert/strict';
import jwt from 'jsonwebtoken';
import { verifyEntitlement } from '../src/entitlement.js';
import { ProxyError } from '../src/types.js';

const opts = { bundleId: 'com.bricky.app', environment: 'Production' };

function token(payload: Record<string, unknown>): string {
  // Unsigned (alg none) JWS — verifyEntitlement decodes, it does not verify
  // signature locally. (Chain verification is a cloud-only concern.)
  return jwt.sign(payload, '', { algorithm: 'none' });
}

const validPayload = {
  originalTransactionId: 'orig-123',
  bundleId: 'com.bricky.app',
  environment: 'Production',
  productId: 'com.bricky.app.pro.monthly',
  expiresDate: Date.now() + 86_400_000,
};

test('accepts an active Pro entitlement and returns userKey', () => {
  const result = verifyEntitlement(token(validPayload), opts);
  assert.equal(result.userKey, 'orig-123');
  assert.equal(result.productId, 'com.bricky.app.pro.monthly');
});

test('rejects a missing token', () => {
  assert.throws(() => verifyEntitlement(undefined, opts), (e: unknown) => {
    return e instanceof ProxyError && e.status === 401 && e.code === 'not_entitled';
  });
});

test('rejects a non-Pro product', () => {
  assert.throws(
    () => verifyEntitlement(token({ ...validPayload, productId: 'com.bricky.app.tip' }), opts),
    (e: unknown) => e instanceof ProxyError && e.status === 403,
  );
});

test('rejects an expired subscription', () => {
  assert.throws(
    () => verifyEntitlement(token({ ...validPayload, expiresDate: Date.now() - 1000 }), opts),
    (e: unknown) => e instanceof ProxyError && e.code === 'not_entitled',
  );
});

test('rejects a revoked subscription', () => {
  assert.throws(
    () => verifyEntitlement(token({ ...validPayload, revocationDate: Date.now() }), opts),
    (e: unknown) => e instanceof ProxyError && e.status === 403,
  );
});

test('rejects a bundle mismatch', () => {
  assert.throws(
    () => verifyEntitlement(token({ ...validPayload, bundleId: 'com.evil.app' }), opts),
    (e: unknown) => e instanceof ProxyError && e.status === 403,
  );
});

test('rejects an environment mismatch', () => {
  assert.throws(
    () => verifyEntitlement(token({ ...validPayload, environment: 'Sandbox' }), opts),
    (e: unknown) => e instanceof ProxyError && e.status === 403,
  );
});
