import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateInquiry } from '../src/support.ts';

test('validateInquiry accepts a clean inquiry', () => {
  const r = validateInquiry({ email: 'a@b.com', message: 'I love Bricky!' });
  assert.equal(r.email, 'a@b.com');
  assert.equal(r.topic, 'general');
});

test('validateInquiry rejects bad email', () => {
  assert.throws(() => validateInquiry({ email: 'nope', message: 'hello there' }), /valid email/);
});

test('validateInquiry rejects short message', () => {
  assert.throws(() => validateInquiry({ email: 'a@b.com', message: 'hi' }), /5–4000/);
});

test('validateInquiry rejects honeypot', () => {
  assert.throws(
    () => validateInquiry({ email: 'a@b.com', message: 'hello there', website: 'spam' }),
    /rejected/,
  );
});

test('validateInquiry trims and caps topic', () => {
  const r = validateInquiry({ email: 'a@b.com', message: 'hello there', topic: '  bug  ' });
  assert.equal(r.topic, 'bug');
});
