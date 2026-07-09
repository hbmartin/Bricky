import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildForgeSystemPrompt,
  forgeGridCap,
  forgeModelFromText,
  parseVoxelDSL,
} from '../src/forge.js';
import { ProxyError } from '../src/types.js';

const config = {
  endpoint: 'https://example.openai.azure.com',
  apiKey: 'k',
  deployment: 'gpt-4o',
  apiVersion: '2024-08-01-preview',
};

function fakeFetch(content: string, ok = true, status = 200): typeof fetch {
  return (async () =>
    ({
      ok,
      status,
      json: async () => ({ choices: [{ message: { content } }] }),
    }) as unknown as Response) as typeof fetch;
}

test('forgeGridCap scales with size', () => {
  assert.equal(forgeGridCap('small'), 10);
  assert.equal(forgeGridCap('medium'), 14);
  assert.equal(forgeGridCap('large'), 18);
});

test('buildForgeSystemPrompt lists allowed colours and the cap', () => {
  const prompt = buildForgeSystemPrompt(12);
  assert.match(prompt, /Red/);
  assert.match(prompt, /at most 12 wide/);
});

test('parseVoxelDSL expands a valid layered model', () => {
  const dsl = JSON.stringify({
    palette: { r: 'Red', g: 'Green' },
    layers: [
      ['rr', 'rr'], // y = 0
      ['.g', 'g.'], // y = 1
    ],
  });
  const grid = parseVoxelDSL(dsl, 18);
  assert.equal(grid.width, 2);
  assert.equal(grid.depth, 2);
  assert.equal(grid.height, 2);
  // 4 red on layer 0 + 2 green on layer 1
  assert.equal(grid.voxels.length, 6);
  assert.ok(grid.voxels.some((v) => v.x === 0 && v.y === 0 && v.z === 0 && v.color === 'Red'));
  assert.ok(grid.voxels.some((v) => v.y === 1 && v.color === 'Green'));
});

test('parseVoxelDSL drops unknown colours and empty cells', () => {
  const dsl = JSON.stringify({
    palette: { r: 'Red', x: 'NotAColor' },
    layers: [['r.x', 'r..']],
  });
  const grid = parseVoxelDSL(dsl, 18);
  // Only the two 'r' cells survive; 'x' maps to an invalid colour, '.' is empty.
  assert.equal(grid.voxels.length, 2);
  assert.ok(grid.voxels.every((v) => v.color === 'Red'));
});

test('parseVoxelDSL clamps to the grid cap', () => {
  const bigRow = 'r'.repeat(30);
  const dsl = JSON.stringify({
    palette: { r: 'Red' },
    layers: Array.from({ length: 30 }, () => [bigRow]),
  });
  const grid = parseVoxelDSL(dsl, 8);
  assert.ok(grid.width <= 8);
  assert.ok(grid.height <= 8);
});

test('parseVoxelDSL returns empty grid for no valid voxels', () => {
  const grid = parseVoxelDSL(JSON.stringify({ palette: {}, layers: [['...']] }), 18);
  assert.equal(grid.voxels.length, 0);
  assert.equal(grid.width, 0);
});

test('parseVoxelDSL throws on malformed JSON', () => {
  assert.throws(() => parseVoxelDSL('not json', 18), ProxyError);
});

test('forgeModelFromText parses an upstream model response', async () => {
  const dsl = JSON.stringify({
    palette: { b: 'Blue' },
    layers: [['bb', 'bb']],
  });
  const grid = await forgeModelFromText('a blue cube', 'small', config, fakeFetch(dsl));
  assert.equal(grid.voxels.length, 4);
  assert.ok(grid.voxels.every((v) => v.color === 'Blue'));
});

test('forgeModelFromText maps upstream failure to ProxyError', async () => {
  await assert.rejects(
    () => forgeModelFromText('x', 'small', config, fakeFetch('', false, 500)),
    ProxyError,
  );
});
