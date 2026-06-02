import {
  ProxyError,
  SUBJECT_CATEGORIES,
  type RecognizedSubject,
  type SubjectCategory,
} from './types.js';

/**
 * Calls Azure OpenAI GPT-4o vision to identify famous subjects in an image and
 * returns a normalized, validated list. The model is instructed to return
 * strict JSON and to honestly report when it can't confidently identify a
 * famous subject (empty list) rather than guessing — we never fabricate.
 */

export interface OpenAIConfig {
  endpoint: string;
  apiKey: string;
  deployment: string;
  apiVersion: string;
}

const SYSTEM_PROMPT = `You identify FAMOUS subjects in a photo: real celebrities, public figures, musicians, cartoon/fictional characters, famous landmarks, and recognizable places (cities, natural wonders).

Rules:
- Only include a subject if it is genuinely famous and you are reasonably confident.
- If you cannot confidently identify any famous subject, return an empty "subjects" array. Do NOT guess at private individuals.
- "confidence" is your honest probability from 0 to 1.
- Keep "summary" to one factual sentence.
- "category" must be one of: person, character, landmark, place, musician, artwork, animal, object, unknown.
Respond ONLY with strict JSON of the form:
{"subjects":[{"name":string,"category":string,"confidence":number,"summary":string,"location":string|null}]}`;

interface AzureChatResponse {
  choices?: Array<{ message?: { content?: string } }>;
}

export async function recognizeWithOpenAI(
  imageBase64: string,
  config: OpenAIConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<RecognizedSubject[]> {
  const url =
    `${config.endpoint.replace(/\/$/, '')}/openai/deployments/` +
    `${config.deployment}/chat/completions?api-version=${config.apiVersion}`;

  const body = {
    messages: [
      { role: 'system', content: SYSTEM_PROMPT },
      {
        role: 'user',
        content: [
          { type: 'text', text: 'Identify the famous subjects in this image.' },
          {
            type: 'image_url',
            image_url: { url: `data:image/jpeg;base64,${imageBase64}` },
          },
        ],
      },
    ],
    temperature: 0.2,
    max_tokens: 700,
    response_format: { type: 'json_object' },
  };

  let response: Response;
  try {
    response = await fetchImpl(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'api-key': config.apiKey,
      },
      body: JSON.stringify(body),
    });
  } catch {
    throw new ProxyError(502, 'upstream_error', 'Recognition service unreachable.');
  }

  if (!response.ok) {
    throw new ProxyError(
      502,
      'upstream_error',
      `Recognition upstream returned ${response.status}.`,
    );
  }

  const payload = (await response.json()) as AzureChatResponse;
  const content = payload.choices?.[0]?.message?.content;
  if (!content) {
    throw new ProxyError(502, 'upstream_error', 'Empty recognition response.');
  }

  return parseSubjects(content);
}

/** Parses + validates the model's JSON, discarding malformed entries. */
export function parseSubjects(raw: string): RecognizedSubject[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(extractJSON(raw));
  } catch {
    throw new ProxyError(502, 'upstream_error', 'Malformed recognition response.');
  }

  const subjectsRaw = (parsed as { subjects?: unknown }).subjects;
  if (!Array.isArray(subjectsRaw)) return [];

  const out: RecognizedSubject[] = [];
  for (const item of subjectsRaw) {
    if (typeof item !== 'object' || item === null) continue;
    const obj = item as Record<string, unknown>;

    const name = typeof obj.name === 'string' ? obj.name.trim() : '';
    if (!name) continue;

    out.push({
      name,
      category: normalizeCategory(obj.category),
      confidence: clamp01(obj.confidence),
      summary: typeof obj.summary === 'string' ? obj.summary.trim() : '',
      location:
        typeof obj.location === 'string' && obj.location.trim().length > 0
          ? obj.location.trim()
          : undefined,
    });
  }
  return out;
}

function extractJSON(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.startsWith('{')) return trimmed;
  const start = trimmed.indexOf('{');
  const end = trimmed.lastIndexOf('}');
  if (start >= 0 && end > start) return trimmed.slice(start, end + 1);
  return trimmed;
}

function normalizeCategory(value: unknown): SubjectCategory {
  if (typeof value === 'string') {
    const lower = value.toLowerCase() as SubjectCategory;
    if (SUBJECT_CATEGORIES.includes(lower)) return lower;
  }
  return 'unknown';
}

function clamp01(value: unknown): number {
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n)) return 0;
  return Math.min(1, Math.max(0, n));
}
