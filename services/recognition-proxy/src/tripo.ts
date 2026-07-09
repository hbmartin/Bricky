import { ProxyError, type ForgeSize } from './types.js';

/**
 * Tripo hosted text→3D client (Set Forge premium tier).
 *
 * Flow (https://platform.tripo3d.ai/docs):
 *   POST  /v2/openapi/task            → { code, data: { task_id } }
 *   GET   /v2/openapi/task/{task_id}  → { code, data: { status, progress, output } }
 *
 * We (1) create a `text_to_model` draft, (2) wait for it, then (3) run a
 * `convert_model` task to **USDZ** so the iOS client's Model I/O voxelizer can
 * read the result (it cannot read Tripo's default GLB). We poll each stage to
 * completion and return the converted model URL.
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

export interface PollOptions {
  fetchImpl?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  maxAttempts?: number;
  pollIntervalMs?: number;
  /** Output format for the convert stage (default USDZ). */
  format?: string;
}

/** Face-count budget by size preset (low-poly is faster, cheaper, brick-friendly). */
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

/** POST a task body and return its task id. */
async function postTask(
  body: Record<string, unknown>,
  config: TripoConfig,
  fetchImpl: typeof fetch,
): Promise<string> {
  const base = config.baseUrl ?? DEFAULT_BASE;
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

/** Create a text→model draft task; returns the task id. */
export async function createTextTask(
  prompt: string,
  size: ForgeSize,
  config: TripoConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<string> {
  return postTask(
    {
      type: 'text_to_model',
      prompt: prompt.trim().slice(0, 1024),
      texture: true,
      pbr: true,
      face_limit: faceLimit(size),
    },
    config,
    fetchImpl,
  );
}

/** Create a convert task that re-exports an existing model in `format` (e.g. USDZ). */
export async function createConvertTask(
  originalTaskId: string,
  format: string,
  config: TripoConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<string> {
  return postTask(
    {
      type: 'convert_model',
      original_model_task_id: originalTaskId,
      format,
    },
    config,
    fetchImpl,
  );
}

/** Upload an image and return its token (used as `file_token` in image tasks). */
export async function uploadImage(
  bytes: Uint8Array,
  mime: string,
  config: TripoConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<string> {
  const base = config.baseUrl ?? DEFAULT_BASE;
  const form = new FormData();
  form.append('file', new Blob([bytes as unknown as BlobPart], { type: mime }), 'image');
  let response: Response;
  try {
    response = await fetchImpl(`${base}/upload/sts`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${config.apiKey}` },
      body: form,
    });
  } catch {
    throw new ProxyError(502, 'upstream_error', 'Image upload service unreachable.');
  }
  if (!response.ok) {
    throw new ProxyError(502, 'upstream_error', `Image upload returned ${response.status}.`);
  }
  const payload = (await response.json()) as {
    code: number;
    data?: { image_token?: string };
    message?: string;
  };
  if (payload.code !== 0 || !payload.data?.image_token) {
    throw new ProxyError(502, 'upstream_error', payload.message ?? 'Image upload was rejected.');
  }
  return payload.data.image_token;
}

/** Create an image→model draft task from an uploaded image token. */
export async function createImageTask(
  imageToken: string,
  imageType: string,
  size: ForgeSize,
  config: TripoConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<string> {
  return postTask(
    {
      type: 'image_to_model',
      file: { type: imageType, file_token: imageToken },
      texture: true,
      pbr: true,
      face_limit: faceLimit(size),
    },
    config,
    fetchImpl,
  );
}

/**
 * Create a multiview→model draft task. `tokens` maps to the fixed order
 * [front, left, back, right]; `null` entries are omitted (front is required).
 */
export async function createMultiviewTask(
  tokens: Array<string | null>,
  imageType: string,
  size: ForgeSize,
  config: TripoConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<string> {
  const files = [0, 1, 2, 3].map((i) => {
    const token = tokens[i];
    return token ? { type: imageType, file_token: token } : {};
  });
  return postTask(
    {
      type: 'multiview_to_model',
      files,
      texture: true,
      pbr: true,
      face_limit: faceLimit(size),
    },
    config,
    fetchImpl,
  );
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

/** Poll a task until it succeeds (returns output) or fails/times out (throws). */
export async function pollUntilComplete(
  taskId: string,
  config: TripoConfig,
  options: PollOptions = {},
): Promise<Record<string, unknown>> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const sleep = options.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  const maxAttempts = options.maxAttempts ?? 90;
  const pollIntervalMs = options.pollIntervalMs ?? 2000;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const task = await getTask(taskId, config, fetchImpl);
    if (task.status === 'success') return task.output;
    if (TERMINAL_FAILURE.has(task.status)) {
      throw new ProxyError(422, 'upstream_error', 'The model could not be generated. Try another description.');
    }
    await sleep(pollIntervalMs);
  }
  throw new ProxyError(504, 'upstream_error', 'Model generation timed out.');
}

/**
 * End-to-end: create a text→model draft, wait for it, convert it to USDZ (so it
 * voxelizes on-device), and return the converted model URL. `sleep` is
 * injectable so tests run instantly.
 */
export async function forgeMeshFromText(
  prompt: string,
  size: ForgeSize,
  config: TripoConfig,
  options: PollOptions = {},
): Promise<TripoResult> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const format = options.format ?? 'USDZ';

  // 1. Draft model.
  const draftId = await createTextTask(prompt, size, config, fetchImpl);
  await pollUntilComplete(draftId, config, options);

  // 2. Convert to a Model I/O-readable format (USDZ).
  const convertId = await createConvertTask(draftId, format, config, fetchImpl);
  const output = await pollUntilComplete(convertId, config, options);

  const result = selectModelUrl(output);
  if (!result) {
    throw new ProxyError(502, 'upstream_error', 'Model finished without a downloadable file.');
  }
  return result;
}

/** Map an image MIME type to Tripo's `file.type` value. */
export function imageTypeForMime(mime: string): string {
  const m = mime.toLowerCase();
  if (m.includes('png')) return 'png';
  if (m.includes('webp')) return 'webp';
  return 'jpeg';
}

/**
 * End-to-end image→3D: upload the image, create an image→model draft, wait,
 * convert to USDZ, and return the converted model URL.
 */
export async function forgeMeshFromImage(
  imageBase64: string,
  mime: string,
  size: ForgeSize,
  config: TripoConfig,
  options: PollOptions = {},
): Promise<TripoResult> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const format = options.format ?? 'USDZ';
  const bytes = Uint8Array.from(Buffer.from(imageBase64, 'base64'));

  // 1. Upload image → token.
  const token = await uploadImage(bytes, mime, config, fetchImpl);

  // 2. Draft model from the image.
  const draftId = await createImageTask(token, imageTypeForMime(mime), size, config, fetchImpl);
  await pollUntilComplete(draftId, config, options);

  // 3. Convert to USDZ.
  const convertId = await createConvertTask(draftId, format, config, fetchImpl);
  const output = await pollUntilComplete(convertId, config, options);

  const result = selectModelUrl(output);
  if (!result) {
    throw new ProxyError(502, 'upstream_error', 'Model finished without a downloadable file.');
  }
  return result;
}

/**
 * End-to-end multiview→3D: upload up to 4 images (front/left/back/right), create
 * a multiview→model draft, wait, convert to USDZ, and return the model URL.
 * Multiple angles yield a genuinely 3D model (not a single-view guess).
 */
export async function forgeMeshFromMultiview(
  imagesBase64: string[],
  mime: string,
  size: ForgeSize,
  config: TripoConfig,
  options: PollOptions = {},
): Promise<TripoResult> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const format = options.format ?? 'USDZ';

  const provided = imagesBase64.slice(0, 4);
  if (provided.length === 0) {
    throw new ProxyError(400, 'bad_request', 'At least one image is required.');
  }

  // 1. Upload each provided view → tokens (front/left/back/right order).
  const tokens: Array<string | null> = [null, null, null, null];
  for (let i = 0; i < provided.length; i++) {
    const bytes = Uint8Array.from(Buffer.from(provided[i], 'base64'));
    tokens[i] = await uploadImage(bytes, mime, config, fetchImpl);
  }

  // 2. Multiview draft.
  const draftId = await createMultiviewTask(tokens, imageTypeForMime(mime), size, config, fetchImpl);
  await pollUntilComplete(draftId, config, options);

  // 3. Convert to USDZ.
  const convertId = await createConvertTask(draftId, format, config, fetchImpl);
  const output = await pollUntilComplete(convertId, config, options);

  const result = selectModelUrl(output);
  if (!result) {
    throw new ProxyError(502, 'upstream_error', 'Model finished without a downloadable file.');
  }
  return result;
}
