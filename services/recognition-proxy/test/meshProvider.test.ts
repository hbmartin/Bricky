import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TripoProvider, createMeshProvider } from '../src/meshProvider.js';
import { ProxyError } from '../src/types.js';

function sequenceFetch(payloads: Array<{ json: unknown }>): typeof fetch {
  let i = 0;
  return (async () => {
    const p = payloads[Math.min(i, payloads.length - 1)];
    i++;
    return { ok: true, status: 200, json: async () => p.json } as unknown as Response;
  }) as typeof fetch;
}

test('createMeshProvider defaults to Tripo when key is set', () => {
  const provider = createMeshProvider({ TRIPO_API_KEY: 'tsk_x' });
  assert.equal(provider.name, 'tripo');
});

test('createMeshProvider honors MESH_PROVIDER=tripo', () => {
  const provider = createMeshProvider({ MESH_PROVIDER: 'Tripo', TRIPO_API_KEY: 'tsk_x' });
  assert.equal(provider.name, 'tripo');
});

test('createMeshProvider throws not_configured when the key is missing', () => {
  assert.throws(() => createMeshProvider({}), (e) => e instanceof ProxyError && e.status === 503);
});

test('createMeshProvider throws for an unknown provider', () => {
  assert.throws(
    () => createMeshProvider({ MESH_PROVIDER: 'acme' }),
    (e) => e instanceof ProxyError && e.status === 503,
  );
});

test('TripoProvider.forgeFromText delegates and returns a model', async () => {
  const provider = new TripoProvider({ apiKey: 'tsk_x' });
  const fetchImpl = sequenceFetch([
    { json: { code: 0, data: { task_id: 'draft1' } } },
    { json: { code: 0, data: { status: 'success', output: {} } } },
    { json: { code: 0, data: { task_id: 'conv1' } } },
    { json: { code: 0, data: { status: 'success', output: { model: 'https://x/m.usdz' } } } },
  ]);
  const result = await provider.forgeFromText('a cat', 'small', {
    fetchImpl,
    sleep: async () => {},
    pollIntervalMs: 0,
  });
  assert.equal(result.modelUrl, 'https://x/m.usdz');
  assert.equal(result.format, 'usdz');
});

test('TripoProvider.forgeFromImage delegates and returns a model', async () => {
  const provider = new TripoProvider({ apiKey: 'tsk_x' });
  const fetchImpl = sequenceFetch([
    { json: { code: 0, data: { image_token: 'img1' } } },
    { json: { code: 0, data: { task_id: 'draftImg' } } },
    { json: { code: 0, data: { status: 'success', output: {} } } },
    { json: { code: 0, data: { task_id: 'conv1' } } },
    { json: { code: 0, data: { status: 'success', output: { model: 'https://x/m.usdz' } } } },
  ]);
  const result = await provider.forgeFromImage('aGVsbG8=', 'image/jpeg', 'small', {
    fetchImpl,
    sleep: async () => {},
    pollIntervalMs: 0,
  });
  assert.equal(result.format, 'usdz');
});
