import { TableClient, type TableEntity } from '@azure/data-tables';
import { ProxyError } from './types.js';

/**
 * Per-user monthly fair-use quota, persisted in Azure Table Storage.
 *
 * PartitionKey = `YYYY-MM` (UTC month), RowKey = the user's stable key. A single
 * `Count` column is incremented atomically (optimistic concurrency via ETag).
 * Rows from prior months are simply never read again — they roll off logically
 * because the partition key changes each month.
 */

const TABLE_NAME = 'recognitionQuota';

interface QuotaEntity extends TableEntity {
  Count: number;
}

export interface QuotaStore {
  /**
   * Reserves one recognition for `userKey` this month. Returns the number
   * remaining AFTER this reservation. Throws `quota_exceeded` (429) when the
   * monthly cap is already reached.
   */
  consume(userKey: string): Promise<{ remaining: number }>;
}

function monthMarker(now = new Date()): string {
  const y = now.getUTCFullYear();
  const m = String(now.getUTCMonth() + 1).padStart(2, '0');
  return `${y}-${m}`;
}

/** Table-Storage-backed quota store for production. */
export class TableQuotaStore implements QuotaStore {
  private readonly client: TableClient;
  private ensured = false;

  constructor(
    connectionString: string,
    private readonly monthlyLimit: number,
  ) {
    this.client = TableClient.fromConnectionString(connectionString, TABLE_NAME);
  }

  private async ensureTable(): Promise<void> {
    if (this.ensured) return;
    await this.client.createTable();
    this.ensured = true;
  }

  async consume(userKey: string): Promise<{ remaining: number }> {
    await this.ensureTable();
    const partitionKey = monthMarker();

    // Retry loop for optimistic-concurrency conflicts.
    for (let attempt = 0; attempt < 5; attempt++) {
      let current: QuotaEntity | undefined;
      try {
        current = await this.client.getEntity<QuotaEntity>(partitionKey, userKey);
      } catch (err: unknown) {
        if (!isNotFound(err)) throw err;
      }

      const used = current?.Count ?? 0;
      if (used >= this.monthlyLimit) {
        throw new ProxyError(
          429,
          'quota_exceeded',
          'Monthly recognition allowance used up.',
        );
      }

      const next: QuotaEntity = {
        partitionKey,
        rowKey: userKey,
        Count: used + 1,
      };

      try {
        if (current) {
          const etag = (current as QuotaEntity & { etag?: string }).etag;
          await this.client.updateEntity(next, 'Replace', { etag });
        } else {
          await this.client.createEntity(next);
        }
        return { remaining: Math.max(0, this.monthlyLimit - next.Count) };
      } catch (err: unknown) {
        if (isConflict(err)) continue; // someone else incremented; retry
        throw err;
      }
    }

    throw new ProxyError(
      429,
      'quota_exceeded',
      'Quota update conflict, please retry.',
    );
  }
}

function statusOf(err: unknown): number | undefined {
  return (err as { statusCode?: number } | undefined)?.statusCode;
}
function isNotFound(err: unknown): boolean {
  return statusOf(err) === 404;
}
function isConflict(err: unknown): boolean {
  const s = statusOf(err);
  return s === 409 || s === 412;
}

export { monthMarker };
