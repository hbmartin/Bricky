import { TableClient, type TableEntity } from '@azure/data-tables';
import { ProxyError, type SupportInquiry } from './types.js';

/**
 * Persists support inquiries from the marketing site contact form into Azure
 * Table Storage — the minimal, cheap "database" for this. PartitionKey is the
 * UTC day (`YYYY-MM-DD`) so inquiries are naturally bucketed by date; RowKey is
 * a timestamp-sortable unique id. No PII beyond the email the user typed.
 */

const TABLE_NAME = 'supportInquiries';

interface InquiryEntity extends TableEntity {
  Email: string;
  Topic: string;
  Message: string;
}

export interface SupportStore {
  save(inquiry: Required<Pick<SupportInquiry, 'email' | 'message'>> & { topic?: string }): Promise<void>;
  list(limit?: number): Promise<StoredInquiry[]>;
}

export interface StoredInquiry {
  id: string;
  date: string;
  email: string;
  topic: string;
  message: string;
}

function dayMarker(now = new Date()): string {
  return now.toISOString().slice(0, 10);
}

/** Table-Storage-backed support store for production. */
export class TableSupportStore implements SupportStore {
  private readonly client: TableClient;
  private ensured = false;

  constructor(connectionString: string) {
    this.client = TableClient.fromConnectionString(connectionString, TABLE_NAME);
  }

  private async ensureTable(): Promise<void> {
    if (this.ensured) return;
    await this.client.createTable();
    this.ensured = true;
  }

  async save(inquiry: { email: string; message: string; topic?: string }): Promise<void> {
    await this.ensureTable();
    const now = new Date();
    const rowKey = `${now.getTime()}-${Math.random().toString(36).slice(2, 8)}`;
    const entity: InquiryEntity = {
      partitionKey: dayMarker(now),
      rowKey,
      Email: inquiry.email,
      Topic: inquiry.topic ?? 'general',
      Message: inquiry.message,
    };
    await this.client.createEntity(entity);
  }

  async list(limit = 200): Promise<StoredInquiry[]> {
    await this.ensureTable();
    const out: StoredInquiry[] = [];
    for await (const e of this.client.listEntities<InquiryEntity>()) {
      out.push({
        id: String(e.rowKey),
        date: String(e.partitionKey),
        email: e.Email,
        topic: e.Topic,
        message: e.Message,
      });
      if (out.length >= limit * 2) break;
    }
    // Newest first by RowKey (which starts with epoch ms).
    out.sort((a, b) => (a.id < b.id ? 1 : -1));
    return out.slice(0, limit);
  }
}

/** Validates + normalizes a raw inquiry, throwing `bad_request` on bad input. */
export function validateInquiry(raw: SupportInquiry | undefined): {
  email: string;
  message: string;
  topic: string;
} {
  if (!raw || typeof raw !== 'object') {
    throw new ProxyError(400, 'bad_request', 'Missing inquiry.');
  }
  // Honeypot: real users leave this blank; bots fill it.
  if (typeof raw.website === 'string' && raw.website.trim().length > 0) {
    throw new ProxyError(400, 'bad_request', 'Submission rejected.');
  }
  const email = typeof raw.email === 'string' ? raw.email.trim() : '';
  const message = typeof raw.message === 'string' ? raw.message.trim() : '';
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
    throw new ProxyError(400, 'bad_request', 'Please enter a valid email address.');
  }
  if (message.length < 5 || message.length > 4000) {
    throw new ProxyError(400, 'bad_request', 'Message must be 5–4000 characters.');
  }
  const topic = typeof raw.topic === 'string' ? raw.topic.trim().slice(0, 64) : 'general';
  return { email, message, topic: topic || 'general' };
}
