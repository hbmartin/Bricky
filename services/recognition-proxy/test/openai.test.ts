import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseSubjects, recognizeWithOpenAI } from '../src/openai.js';
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

test('parseSubjects normalizes valid entries', () => {
  const subjects = parseSubjects(
    JSON.stringify({
      subjects: [
        {
          name: 'Eiffel Tower',
          category: 'landmark',
          confidence: 0.94,
          summary: 'Tower in Paris.',
          location: 'Paris, France',
        },
      ],
    }),
  );
  assert.equal(subjects.length, 1);
  assert.equal(subjects[0].name, 'Eiffel Tower');
  assert.equal(subjects[0].category, 'landmark');
  assert.equal(subjects[0].confidence, 0.94);
  assert.equal(subjects[0].location, 'Paris, France');
});

test('parseSubjects clamps confidence and defaults bad category', () => {
  const subjects = parseSubjects(
    JSON.stringify({
      subjects: [{ name: 'X', category: 'nope', confidence: 5 }],
    }),
  );
  assert.equal(subjects[0].confidence, 1);
  assert.equal(subjects[0].category, 'unknown');
  assert.equal(subjects[0].summary, '');
  assert.equal(subjects[0].location, undefined);
});

test('parseSubjects drops entries without a name', () => {
  const subjects = parseSubjects(
    JSON.stringify({ subjects: [{ category: 'person', confidence: 0.5 }] }),
  );
  assert.equal(subjects.length, 0);
});

test('parseSubjects returns empty for empty array', () => {
  assert.deepEqual(parseSubjects(JSON.stringify({ subjects: [] })), []);
});

test('parseSubjects extracts JSON wrapped in prose', () => {
  const subjects = parseSubjects(
    'Here you go: {"subjects":[{"name":"Batman","category":"character","confidence":0.8,"summary":"Hero."}]} done',
  );
  assert.equal(subjects[0].name, 'Batman');
});

test('parseSubjects throws upstream_error on malformed JSON', () => {
  assert.throws(() => parseSubjects('not json'), (e: unknown) => {
    return e instanceof ProxyError && e.code === 'upstream_error';
  });
});

test('recognizeWithOpenAI maps non-200 to upstream_error', async () => {
  await assert.rejects(
    () => recognizeWithOpenAI('abc', config, fakeFetch('', false, 500)),
    (e: unknown) => e instanceof ProxyError && e.status === 502,
  );
});

test('recognizeWithOpenAI parses a successful response', async () => {
  const content = JSON.stringify({
    subjects: [{ name: 'Taylor Swift', category: 'musician', confidence: 0.9, summary: 'Singer.' }],
  });
  const subjects = await recognizeWithOpenAI('abc', config, fakeFetch(content));
  assert.equal(subjects[0].category, 'musician');
});
