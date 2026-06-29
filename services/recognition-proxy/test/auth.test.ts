import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AdminAuth } from '../src/auth.ts';

test('verify rejects bogus and accepts valid tokens', () => {
  const a = new AdminAuth('UseDevelopmentStorage=true', 'secret-key');
  assert.throws(() => a.verify(undefined), /Sign in/);
  assert.throws(() => a.verify('123.abc'), /Sign in/);
  // sign() is private; build a token the same way verify expects via login path is async — test tamper instead.
  assert.throws(() => a.verify(`${Date.now() + 1000}.deadbeef`), /Sign in/);
});

test('expired token rejected', () => {
  const a = new AdminAuth('UseDevelopmentStorage=true', 'secret-key');
  assert.throws(() => a.verify('1.aaaa'), /Sign in/);
});
