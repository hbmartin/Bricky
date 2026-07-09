import { ProxyError, type ForgeSize } from './types.js';

/**
 * Tripo hosted text→3D client (Set Forge premium tier).
 *
 * Flow (https://platform.tripo3d.ai/docs):
 *   POST  /v2/openapi/task            → { code, data: { task_id } }
 *   GET   /v2/openapi/task/{task_id}  → { code, data: { status, progress, output } }
 * We create a `text_to_model` task, poll until `success`, and return the best
 * available model URL. The iOS client downloads and voxelizes it on-device.
 */

const DEFAULT_BASE = 'https://api.tripo3d.ai/v2/openapi';

export interface TripoConfig {
  apiKey: string;
  baseUrl?: string;
}

interface TripoCreateResponse {
  code: number;
  data?: { task_id?: string };
  message?: string;
}

interface TripoTaskResponse {
  code: number;
  data?: {
    status?: string;
    progress?: number;
    output?: Record<string, unknown>;
  };
  message?: string;
}

export interface TripoResult {
  modelUrl: string;
  format: string;
}

/** Face-count budget by size preset (low-poly is faster + cheaper + brick-friendly). */
function faceLimit(size: ForgeSize): number {
  switch (size) {
    case 'small':
      return 2000;
    case 'medium':
      return 6000;
    case 'large':
      return 12000;
  }
}

/** Create a text→model task; returns the task id. */
export async function createTextTask(
  prompt: string,
  size: ForgeSize,
  config: TripoConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<string> {
  const base = config.baseUrl ?? DEFAULT_BASE;
  const body = {
    type: 'text_to_model',
    prompt: prompt.trim().slice(0, 1024),
    texture: true,
    pbr: true,
    face_limit: faceLimit(size),
  };

  let response: Response;
  try {
    response = await fetchImpl(`${base}/task`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${config.apiKey}`,
      },
      body: JSON.stringify(body),
    });
  } catch {
    throw new ProxyError(502, 'upstream_error', 'Model service unreachable.');
  }
  if (!response.ok) {
    throw new ProxyError(502, 'upstream_error', `Model upstream returned ${response.status}.`);
  }

  const payload = (await response.json()) as TripoCreateResponse;
  if (payload.code !== 0 || !payload.data?.task_id) {
    throw new ProxyError(502, 'upstream_error', payload.message ?? 'Model task was rejected.');
  }
  return payload.data.task_id;
}

/** Fetch a task's current status + output. */
export async function getTask(
  taskId: string,
  config: TripoConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<{ status: string; progress: number; output: Record<string, unknown> }> {
  const base = config.baseUrl ?? DEFAULT_BASE;
  let response: Response;
  try {
    response = await fetchImpl(`${base}/task/${taskId}`, {
      headers: { Authorization: `Bearer ${config.apiKey}` },
    });
  } catch {
    throw new ProxyError(502, 'upstream_error', 'Model service unreachable.');
  }
  if (!response.ok) {
    throw new ProxyError(502, 'upstream_error', `Model status returned ${response.status}.`);
  }
  const payload = (await response.json()) as TripoTaskResponse;
  if (payload.code !== 0 || !payload.data) {
    throw new ProxyError(502, 'upstream_error', payload.message ?? 'Model status was rejected.');
  }
  return {
    status: String(payload.data.status ?? 'unknown'),
    progress: Number(payload.data.progress ?? 0),
    output: payload.data.output ?? {},
  };
}

/** Choose the best model URL from a task's output, preferring textured PBR. */
export function selectModelUrl(output: Record<string, unknown>): TripoResult | null {
  const candidates = ['pbr_model', 'model', 'base_model', 'rendered_model'];
  for (const key of candidates) {
    const value = output[key];
    const url = typeof value === 'string' ? value : (value as { url?: string })?.url;
    if (typeof url === 'string' && url.startsWith('http')) {
      return { modelUrl: url, format: extension(url) };
    }
  }
  return null;
}

function extension(url: string): string {
  const clean = url.split('?')[0];
  const dot = clean.lastIndexOf('.');
  return dot >= 0 ? clean.slice(dot + 1).toLowerCase() : 'glb';
}

const TERMINAL_FAILURE = new Set(['failed', 'banned', 'expired', 'cancelled', 'unknown']);

/**
 * End-to-end: create a text→model task and poll until it produces a model URL.
 * `sleep` is injectable so tests run instantly.
 */
export async function forgeMeshFromText(
  prompt: string,
  size: ForgeSize,
  config: TripoConfig,
  options: {
    fetchImpl?: typeof fetch;
    sleep?: (ms: number) => Promise<void>;
    maxAttempts?: number;
    pollIntervalMs?: number;
  } = {},
): Promise<TripoResult> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const sleep = options.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  const maxAttempts = options.maxAttempts ?? 90;
  const pollIntervalMs = options.pollIntervalMs ?? 2000;

  const taskId = await createTextTask(prompt, size, config, fetchImpl);

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const task = await getTask(taskId, config, fetchImpl);
    if (task.status === 'success') {
      const result = selectModelUrl(task.output);
      if (!result) {
        throw new ProxyError(502, 'upstream_error', 'Model finished without a downloadable file.');
      }
      return result;
    }
    if (TERMINAL_FAILURE.has(task.status)) {
      throw new ProxyError(422, 'upstream_error', 'The model could not be generated. Try another description.');
    }
    await sleep(pollIntervalMs);
  }

  throw new ProxyError(504, 'upstream_error', 'Model generation timed out.');
}
