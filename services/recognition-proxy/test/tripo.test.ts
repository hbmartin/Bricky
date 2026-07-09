import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createConvertTask,
  createImageTask,
  createMultiviewTask,
  createTextTask,
  forgeMeshFromImage,
  forgeMeshFromMultiview,
  forgeMeshFromText,
  getTask,
  imageTypeForMime,
  selectModelUrl,
  uploadImage,
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

test('createConvertTask returns a task id', async () => {
  const fetchImpl = sequenceFetch([{ json: { code: 0, data: { task_id: 'conv1' } } }]);
  const id = await createConvertTask('draft1', 'USDZ', config, fetchImpl);
  assert.equal(id, 'conv1');
});

test('imageTypeForMime maps MIME to Tripo type', () => {
  assert.equal(imageTypeForMime('image/png'), 'png');
  assert.equal(imageTypeForMime('image/webp'), 'webp');
  assert.equal(imageTypeForMime('image/jpeg'), 'jpeg');
  assert.equal(imageTypeForMime('anything'), 'jpeg');
});

test('uploadImage returns an image token', async () => {
  const fetchImpl = sequenceFetch([{ json: { code: 0, data: { image_token: 'img1' } } }]);
  const token = await uploadImage(new Uint8Array([1, 2, 3]), 'image/jpeg', config, fetchImpl);
  assert.equal(token, 'img1');
});

test('createImageTask returns a task id', async () => {
  const fetchImpl = sequenceFetch([{ json: { code: 0, data: { task_id: 'draftImg' } } }]);
  const id = await createImageTask('img1', 'jpeg', 'small', config, fetchImpl);
  assert.equal(id, 'draftImg');
});

test('createMultiviewTask returns a task id', async () => {
  const fetchImpl = sequenceFetch([{ json: { code: 0, data: { task_id: 'draftMV' } } }]);
  const id = await createMultiviewTask(['a', null, 'c', null], 'jpeg', 'small', config, fetchImpl);
  assert.equal(id, 'draftMV');
});

test('forgeMeshFromMultiview uploads views, drafts, converts to USDZ', async () => {
  const fetchImpl = sequenceFetch([
    { json: { code: 0, data: { image_token: 'front' } } },   // upload front
    { json: { code: 0, data: { image_token: 'right' } } },   // upload right
    { json: { code: 0, data: { task_id: 'draftMV' } } },     // multiview task
    { json: { code: 0, data: { status: 'success', output: {} } } },
    { json: { code: 0, data: { task_id: 'conv1' } } },
    { json: { code: 0, data: { status: 'success', output: { model: 'https://x/m.usdz' } } } },
  ]);
  const result = await forgeMeshFromMultiview(['aGVsbG8=', 'd29ybGQ='], 'image/jpeg', 'small', config, {
    fetchImpl,
    sleep: async () => {},
    pollIntervalMs: 0,
  });
  assert.equal(result.format, 'usdz');
});

test('forgeMeshFromImage uploads, drafts, converts, and returns USDZ', async () => {
  const fetchImpl = sequenceFetch([
    { json: { code: 0, data: { image_token: 'img1' } } },                            // upload
    { json: { code: 0, data: { task_id: 'draftImg' } } },                            // create image task
    { json: { code: 0, data: { status: 'success', output: {} } } },                  // draft done
    { json: { code: 0, data: { task_id: 'conv1' } } },                               // create convert
    { json: { code: 0, data: { status: 'success', output: { model: 'https://x/m.usdz' } } } }, // convert done
  ]);
  const result = await forgeMeshFromImage('aGVsbG8gd29ybGQ=', 'image/jpeg', 'small', config, {
    fetchImpl,
    sleep: async () => {},
    pollIntervalMs: 0,
  });
  assert.equal(result.modelUrl, 'https://x/m.usdz');
  assert.equal(result.format, 'usdz');
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

test('forgeMeshFromText drafts, converts to USDZ, and returns the model', async () => {
  const fetchImpl = sequenceFetch([
    { json: { code: 0, data: { task_id: 'draft1' } } },                              // create draft
    { json: { code: 0, data: { status: 'running', progress: 50, output: {} } } },    // poll draft
    { json: { code: 0, data: { status: 'success', output: {} } } },                  // draft done
    { json: { code: 0, data: { task_id: 'conv1' } } },                               // create convert
    { json: { code: 0, data: { status: 'success', output: { model: 'https://x/m.usdz' } } } }, // convert done
  ]);
  const result = await forgeMeshFromText('a cat', 'small', config, {
    fetchImpl,
    sleep: async () => {},
    pollIntervalMs: 0,
  });
  assert.equal(result.modelUrl, 'https://x/m.usdz');
  assert.equal(result.format, 'usdz');
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
