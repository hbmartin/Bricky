import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseSets, identifySetWithOpenAI } from '../src/openai.js';
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

test('parseSets normalizes valid candidates', () => {
  const sets = parseSets(
    JSON.stringify({
      candidates: [
        {
          setNumber: '75192',
          name: 'Millennium Falcon',
          theme: 'Star Wars',
          year: 2017,
          confidence: 0.91,
          summary: 'UCS Millennium Falcon.',
        },
      ],
    }),
  );
  assert.equal(sets.length, 1);
  assert.equal(sets[0].setNumber, '75192');
  assert.equal(sets[0].name, 'Millennium Falcon');
  assert.equal(sets[0].theme, 'Star Wars');
  assert.equal(sets[0].year, 2017);
  assert.equal(sets[0].confidence, 0.91);
});

test('parseSets clamps confidence and tolerates numeric setNumber', () => {
  const sets = parseSets(
    JSON.stringify({
      candidates: [{ setNumber: 10256, name: 'Taj Mahal', confidence: 3 }],
    }),
  );
  assert.equal(sets[0].setNumber, '10256');
  assert.equal(sets[0].confidence, 1);
  assert.equal(sets[0].theme, undefined);
  assert.equal(sets[0].summary, '');
});

test('parseSets drops candidates without a name', () => {
  const sets = parseSets(
    JSON.stringify({ candidates: [{ setNumber: '123', confidence: 0.5 }] }),
  );
  assert.equal(sets.length, 0);
});

test('parseSets rejects implausible years', () => {
  const sets = parseSets(
    JSON.stringify({
      candidates: [{ setNumber: '1', name: 'X', year: 1800, confidence: 0.5 }],
    }),
  );
  assert.equal(sets[0].year, undefined);
});

test('parseSets returns empty for empty array', () => {
  assert.deepEqual(parseSets(JSON.stringify({ candidates: [] })), []);
});

test('parseSets extracts JSON wrapped in prose', () => {
  const sets = parseSets(
    'Sure: {"candidates":[{"setNumber":"21318","name":"Tree House","confidence":0.7,"summary":"Ideas tree house."}]} done',
  );
  assert.equal(sets[0].name, 'Tree House');
});

test('parseSets throws upstream_error on malformed JSON', () => {
  assert.throws(
    () => parseSets('not json'),
    (e: unknown) => e instanceof ProxyError && e.code === 'upstream_error',
  );
});

test('identifySetWithOpenAI maps non-200 to upstream_error', async () => {
  await assert.rejects(
    () => identifySetWithOpenAI('abc', config, fakeFetch('', false, 500)),
    (e: unknown) => e instanceof ProxyError && e.status === 502,
  );
});

test('identifySetWithOpenAI parses a successful response', async () => {
  const content = JSON.stringify({
    candidates: [
      { setNumber: '10307', name: 'Eiffel Tower', theme: 'Icons', year: 2022, confidence: 0.88, summary: 'Tall.' },
    ],
  });
  const sets = await identifySetWithOpenAI('abc', config, fakeFetch(content));
  assert.equal(sets[0].setNumber, '10307');
  assert.equal(sets[0].theme, 'Icons');
});
