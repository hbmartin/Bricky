import { TableClient, type TableEntity } from '@azure/data-tables';
import { createHmac, randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { ProxyError } from './types.js';

/**
 * Tiny single-admin auth for the support inbox. The (one) credential is stored
 * in Azure Table Storage: a scrypt hash of the password the admin sets on first
 * visit. Login returns a short-lived HMAC token signed with ADMIN_SECRET — no
 * sessions, no DB, no extra cost. Username is fixed to "ami".
 */

const TABLE_NAME = 'adminAuth';
const PK = 'auth';
const USER = 'ami';
const TOKEN_TTL_MS = 12 * 60 * 60 * 1000; // 12h

interface AuthEntity extends TableEntity {
  Salt: string;
  Hash: string;
}

export class AdminAuth {
  private readonly client: TableClient;
  private ensured = false;

  constructor(connectionString: string, private readonly secret: string) {
    this.client = TableClient.fromConnectionString(connectionString, TABLE_NAME);
  }

  private async ensureTable(): Promise<void> {
    if (this.ensured) return;
    await this.client.createTable();
    this.ensured = true;
  }

  private async current(): Promise<AuthEntity | undefined> {
    await this.ensureTable();
    try {
      return await this.client.getEntity<AuthEntity>(PK, USER);
    } catch {
      return undefined;
    }
  }

  /** True once a password has been set. */
  async isConfigured(): Promise<boolean> {
    return (await this.current()) !== undefined;
  }

  /** Sets the password on first run only. Throws if already configured. */
  async setPassword(password: string): Promise<void> {
    if (typeof password !== 'string' || password.length < 8 || password.length > 128) {
      throw new ProxyError(400, 'bad_request', 'Password must be 8–128 characters.');
    }
    if (await this.isConfigured()) {
      throw new ProxyError(400, 'bad_request', 'Password already set.');
    }
    const salt = randomBytes(16).toString('hex');
    const hash = scryptSync(password, salt, 32).toString('hex');
    await this.client.createEntity({ partitionKey: PK, rowKey: USER, Salt: salt, Hash: hash });
  }

  /** Verifies a password and returns a signed token, or throws not_entitled. */
  async login(password: string): Promise<string> {
    const e = await this.current();
    if (!e) throw new ProxyError(400, 'bad_request', 'Password not set yet.');
    const got = scryptSync(password ?? '', e.Salt, 32);
    const want = Buffer.from(e.Hash, 'hex');
    if (got.length !== want.length || !timingSafeEqual(got, want)) {
      throw new ProxyError(403, 'not_entitled', 'Wrong password.');
    }
    return this.sign();
  }

  private sign(): string {
    const exp = Date.now() + TOKEN_TTL_MS;
    const sig = createHmac('sha256', this.secret).update(`${USER}:${exp}`).digest('hex');
    return `${exp}.${sig}`;
  }

  /** Throws not_entitled unless the token is valid and unexpired. */
  verify(token: string | undefined): void {
    const [expStr, sig] = (token ?? '').split('.');
    const exp = Number(expStr);
    if (!exp || !sig || Date.now() > exp) throw new ProxyError(403, 'not_entitled', 'Sign in required.');
    const want = createHmac('sha256', this.secret).update(`${USER}:${exp}`).digest('hex');
    const a = Buffer.from(sig);
    const b = Buffer.from(want);
    if (a.length !== b.length || !timingSafeEqual(a, b)) {
      throw new ProxyError(403, 'not_entitled', 'Sign in required.');
    }
  }
}
