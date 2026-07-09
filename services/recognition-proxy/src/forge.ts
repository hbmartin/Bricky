import {
  FORGE_COLORS,
  ProxyError,
  type ForgeSize,
  type ForgeVoxel,
} from './types.js';
import { type OpenAIConfig } from './openai.js';

/**
 * Set Forge text → voxel model (Phase 2).
 *
 * Asks Azure OpenAI (GPT-4o) to author a coarse, brick-compatible voxel model
 * for a described subject, returned as a compact layered ASCII DSL. The server
 * validates + expands the DSL into a flat voxel list the iOS client turns into
 * a `VoxelModel` and runs through its on-device brick engine.
 *
 * The DSL keeps token cost low and is easy for the model to author reliably:
 *   {
 *     "palette": { "r": "Red", "g": "Green", ... },   // char → LegoColor name
 *     "layers":  [ ["..r..", "..r.."], ... ]           // bottom (y=0) → top
 *   }
 * Each layer is an array of depth rows (front → back); each character is a
 * palette key or '.'/' ' for empty.
 */

interface AzureChatResponse {
  choices?: Array<{ message?: { content?: string } }>;
}

export interface ForgeGrid {
  width: number;
  height: number;
  depth: number;
  voxels: ForgeVoxel[];
}

/** Grid cap per size preset. Kept small so the model can author it reliably. */
export function forgeGridCap(size: ForgeSize): number {
  switch (size) {
    case 'small':
      return 10;
    case 'medium':
      return 14;
    case 'large':
      return 18;
  }
}

export function buildForgeSystemPrompt(cap: number): string {
  return `You design blocky, brick-compatible 3D models (think Minecraft-style voxel builds) that can be built out of toy bricks.

You output a JSON voxel model made of horizontal layers, from the BOTTOM layer up.

Strict rules:
- Respond with ONLY strict JSON of the form:
  {"palette":{"<char>":"<ColorName>"},"layers":[["row","row"],["row","row"]]}
- "palette" maps single lowercase characters to colour names.
- Allowed colour names ONLY: ${FORGE_COLORS.join(', ')}.
- "layers" is an array of layers, bottom first. Each layer is an array of rows (front to back). Each row is a string; each character is a palette key, or '.' for empty space.
- The grid must be at most ${cap} wide, ${cap} deep, and ${cap} tall (at most ${cap} layers, each at most ${cap} rows of at most ${cap} characters).
- Every layer must have the SAME width and depth (pad rows with '.').
- Keep it recognisable and reasonably solid. Use colour to convey key features.
- IMPORTANT: keep it buildable — a filled cell should generally sit on top of a filled cell in the layer below (avoid floating parts).
- Do not include comments, explanations, or markdown. JSON only.`;
}

/**
 * Parse + validate the model's DSL into an expanded, clamped voxel grid.
 * Malformed entries are dropped rather than throwing, so a partially valid
 * response still yields a usable model. Returns an empty grid if nothing valid.
 */
export function parseVoxelDSL(raw: string, cap: number): ForgeGrid {
  let parsed: unknown;
  try {
    parsed = JSON.parse(extractJSON(raw));
  } catch {
    throw new ProxyError(502, 'upstream_error', 'Malformed model response.');
  }

  const obj = parsed as { palette?: unknown; layers?: unknown };
  const palette = normalizePalette(obj.palette);
  const layers = Array.isArray(obj.layers) ? obj.layers : [];

  const voxels: ForgeVoxel[] = [];
  let maxX = 0;
  let maxZ = 0;
  let maxY = 0;

  const layerCount = Math.min(layers.length, cap);
  for (let y = 0; y < layerCount; y++) {
    const rows = layers[y];
    if (!Array.isArray(rows)) continue;
    const rowCount = Math.min(rows.length, cap);
    for (let z = 0; z < rowCount; z++) {
      const row = rows[z];
      if (typeof row !== 'string') continue;
      const width = Math.min(row.length, cap);
      for (let x = 0; x < width; x++) {
        const ch = row[x];
        if (ch === '.' || ch === ' ') continue;
        const color = palette[ch];
        if (!color) continue;
        voxels.push({ x, y, z, color });
        if (x > maxX) maxX = x;
        if (z > maxZ) maxZ = z;
        if (y > maxY) maxY = y;
      }
    }
  }

  if (voxels.length === 0) {
    return { width: 0, height: 0, depth: 0, voxels: [] };
  }
  return { width: maxX + 1, height: maxY + 1, depth: maxZ + 1, voxels };
}

/** Map palette chars → validated colour names (invalid entries dropped). */
function normalizePalette(raw: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (typeof raw !== 'object' || raw === null) return out;
  const lookup = new Map(FORGE_COLORS.map((c) => [c.toLowerCase(), c]));
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (key.length !== 1) continue;
    if (typeof value !== 'string') continue;
    const canonical = lookup.get(value.trim().toLowerCase());
    if (canonical) out[key] = canonical;
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

/**
 * Call Azure OpenAI to forge a voxel model from a text subject. Returns an
 * expanded voxel grid; throws `ProxyError` on transport/upstream failure.
 */
export async function forgeModelFromText(
  prompt: string,
  size: ForgeSize,
  config: OpenAIConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<ForgeGrid> {
  const cap = forgeGridCap(size);
  const url =
    `${config.endpoint.replace(/\/$/, '')}/openai/deployments/` +
    `${config.deployment}/chat/completions?api-version=${config.apiVersion}`;

  const body = {
    messages: [
      { role: 'system', content: buildForgeSystemPrompt(cap) },
      {
        role: 'user',
        content: `Design a brick model of: ${prompt.trim()}`,
      },
    ],
    temperature: 0.5,
    max_tokens: 4000,
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
    throw new ProxyError(502, 'upstream_error', 'Model service unreachable.');
  }

  if (!response.ok) {
    throw new ProxyError(502, 'upstream_error', `Model upstream returned ${response.status}.`);
  }

  const payload = (await response.json()) as AzureChatResponse;
  const content = payload.choices?.[0]?.message?.content;
  if (!content) {
    throw new ProxyError(502, 'upstream_error', 'Empty model response.');
  }

  return parseVoxelDSL(content, cap);
}
