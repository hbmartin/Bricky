/**
 * Shared types mirroring the iOS `RecognitionResult` / `RecognizedSubject`
 * Codable contract. The proxy is the source of truth for this shape.
 */

export type SubjectCategory =
  | 'person'
  | 'character'
  | 'landmark'
  | 'place'
  | 'musician'
  | 'artwork'
  | 'animal'
  | 'object'
  | 'unknown';

export const SUBJECT_CATEGORIES: readonly SubjectCategory[] = [
  'person',
  'character',
  'landmark',
  'place',
  'musician',
  'artwork',
  'animal',
  'object',
  'unknown',
];

export interface RecognizedSubject {
  name: string;
  category: SubjectCategory;
  /** Clamped 0...1. */
  confidence: number;
  summary: string;
  location?: string;
}

export interface RecognitionResult {
  subjects: RecognizedSubject[];
  remainingQuota: number;
}

export interface RecognitionRequest {
  imageBase64: string;
  entitlementToken: string;
}

/**
 * One LEGO set proposed by the vision model for a scanned built model. The iOS
 * app grounds each proposal against its bundled set catalog before display.
 */
export interface IdentifiedSet {
  /** Official set number, e.g. "75192". */
  setNumber: string;
  name: string;
  theme?: string;
  year?: number;
  /** Clamped 0...1. */
  confidence: number;
  summary: string;
}

export interface SetIdentificationResult {
  candidates: IdentifiedSet[];
  remainingQuota: number;
}

export interface SetIdentificationRequest {
  imageBase64: string;
  entitlementToken: string;
}

export type ErrorCode =
  | 'bad_request'
  | 'not_entitled'
  | 'quota_exceeded'
  | 'upstream_error'
  | 'not_configured';

export interface ErrorBody {
  error: string;
  code: ErrorCode;
}

/** Thrown by handlers to short-circuit with an HTTP status + machine code. */
export class ProxyError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: ErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'ProxyError';
  }
}
