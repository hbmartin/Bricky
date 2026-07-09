import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createTextTask,
  forgeMeshFromText,
  getTask,
  selectModelUrl,
} from '../src/tripo.js';
import { ProxyError } from '../src/types.js';

const config = { apiKey: 'tsk_test' };

/** Fetch stub that returns queued JSON payloads in sequence. */
function sequenceFetch(payloads: Array<{ ok?: boolean; status?: number; json: unknown }>): typeof fetch {
  let i = 0;
  return (async () => {
    const p = payloads[Math.min(i, payloads.length - 1)];
    i++;
    return {
      ok: p.ok ?? true,
      status: p.status ?? 200,
      json: async () => p.json,
    } as unknown as Response;
  }) as typeof fetch;
}

test('createTextTask returns a task id', async () => {
  const fetchImpl = sequenceFetch([{ json: { code: 0, data: { task_id: 'abc123' } } }]);
  const id = await createTextTask('a cat', 'small', config, fetchImpl);
  assert.equal(id, 'abc123');
});

test('createTextTask throws on rejected code', async () => {
  const fetchImpl = sequenceFetch([{ json: { code: 2000, message: 'bad' } }]);
  await assert.rejects(() => createTextTask('x', 'small', config, fetchImpl), ProxyError);
});

test('getTask parses status + output', async () => {
  const fetchImpl = sequenceFetch([
    { json: { code: 0, data: { status: 'running', progress: 40, output: {} } } },
  ]);
  const task = await getTask('abc', config, fetchImpl);
  assert.equal(task.status, 'running');
  assert.equal(task.progress, 40);
});

test('selectModelUrl prefers pbr_model and detects format', () => {
  const r = selectModelUrl({ model: 'https://x/y.glb', pbr_model: 'https://x/z.usdz' });
  assert.equal(r?.modelUrl, 'https://x/z.usdz');
  assert.equal(r?.format, 'usdz');
});

test('selectModelUrl handles object-wrapped url and query strings', () => {
  const r = selectModelUrl({ model: { url: 'https://x/y.glb?sig=abc' } });
  assert.equal(r?.modelUrl, 'https://x/y.glb?sig=abc');
  assert.equal(r?.format, 'glb');
});

test('selectModelUrl returns null when no model', () => {
  assert.equal(selectModelUrl({ rendered_image: 'https://x/y.png' }), null);
});

test('forgeMeshFromText polls until success and returns model', async () => {
  const fetchImpl = sequenceFetch([
    { json: { code: 0, data: { task_id: 't1' } } },        // create
    { json: { code: 0, data: { status: 'queued', output: {} } } },
    { json: { code: 0, data: { status: 'running', progress: 50, output: {} } } },
    { json: { code: 0, data: { status: 'success', output: { model: 'https://x/m.glb' } } } },
  ]);
  const result = await forgeMeshFromText('a cat', 'small', config, {
    fetchImpl,
    sleep: async () => {},
    pollIntervalMs: 0,
  });
  assert.equal(result.modelUrl, 'https://x/m.glb');
  assert.equal(result.format, 'glb');
});

test('forgeMeshFromText throws on terminal failure', async () => {
  const fetchImpl = sequenceFetch([
    { json: { code: 0, data: { task_id: 't1' } } },
    { json: { code: 0, data: { status: 'failed', output: {} } } },
  ]);
  await assert.rejects(
    () => forgeMeshFromText('x', 'small', config, { fetchImpl, sleep: async () => {} }),
    ProxyError,
  );
});

test('forgeMeshFromText times out after maxAttempts', async () => {
  const fetchImpl = sequenceFetch([
    { json: { code: 0, data: { task_id: 't1' } } },
    { json: { code: 0, data: { status: 'running', output: {} } } },
  ]);
  await assert.rejects(
    () => forgeMeshFromText('x', 'small', config, { fetchImpl, sleep: async () => {}, maxAttempts: 3 }),
    ProxyError,
  );
});
