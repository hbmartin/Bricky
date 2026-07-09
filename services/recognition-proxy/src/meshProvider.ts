import { ProxyError, type ForgeSize } from './types.js';
import {
  forgeMeshFromImage as forgeTripoMeshFromImage,
  forgeMeshFromText as forgeTripoMesh,
  type PollOptions,
  type TripoConfig,
  type TripoResult,
} from './tripo.js';

/**
 * Provider-agnostic mesh generation.
 *
 * Every hosted text→3D vendor (Tripo today; Meshy / CSM / Rodin next) is exposed
 * behind the same `MeshProvider` interface, so the Function handler and the iOS
 * client never depend on a specific vendor. Swap vendors by setting the
 * `MESH_PROVIDER` app setting and that provider's API-key setting — no code
 * change in the handler, no app update.
 */

export interface MeshResult {
  modelUrl: string;
  format: string;
}

export interface MeshProvider {
  readonly name: string;
  /**
   * Forge a 3D model from text and return a downloadable model URL in a
   * Model I/O-readable format (USDZ/OBJ) so the iOS client can voxelize it.
   */
  forgeFromText(prompt: string, size: ForgeSize, options?: PollOptions): Promise<MeshResult>;
  /**
   * Forge a 3D model from a base64 image (same output contract as text).
   */
  forgeFromImage(
    imageBase64: string,
    mime: string,
    size: ForgeSize,
    options?: PollOptions,
  ): Promise<MeshResult>;
}

/** Tripo implementation (thin wrapper over the Tripo client). */
export class TripoProvider implements MeshProvider {
  readonly name = 'tripo';
  constructor(private readonly config: TripoConfig) {}

  forgeFromText(prompt: string, size: ForgeSize, options?: PollOptions): Promise<TripoResult> {
    return forgeTripoMesh(prompt, size, this.config, options ?? {});
  }

  forgeFromImage(
    imageBase64: string,
    mime: string,
    size: ForgeSize,
    options?: PollOptions,
  ): Promise<TripoResult> {
    return forgeTripoMeshFromImage(imageBase64, mime, size, this.config, options ?? {});
  }
}

type Env = Record<string, string | undefined>;

function requireEnv(env: Env, name: string): string {
  const v = env[name];
  if (!v || v.length === 0) {
    throw new ProxyError(503, 'not_configured', `Missing configuration: ${name}.`);
  }
  return v;
}

/**
 * Build the configured mesh provider from environment. Defaults to Tripo.
 *
 * To add a vendor: implement a `MeshProvider` and add a `case` here that reads
 * its API key. Nothing else in the pipeline changes.
 */
export function createMeshProvider(env: Env = process.env): MeshProvider {
  const name = (env.MESH_PROVIDER ?? 'tripo').trim().toLowerCase();
  switch (name) {
    case 'tripo':
      return new TripoProvider({ apiKey: requireEnv(env, 'TRIPO_API_KEY') });
    // case 'meshy': return new MeshyProvider({ apiKey: requireEnv(env, 'MESHY_API_KEY') });
    // case 'csm':   return new CSMProvider({ apiKey: requireEnv(env, 'CSM_API_KEY') });
    // case 'rodin': return new RodinProvider({ apiKey: requireEnv(env, 'RODIN_API_KEY') });
    default:
      throw new ProxyError(503, 'not_configured', `Unknown MESH_PROVIDER '${name}'.`);
  }
}
