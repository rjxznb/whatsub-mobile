# iOS Monetization — Phase 1 (Backend Entitlement Infra) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the backend foundation for iOS in-app-purchase entitlements (per-account trial timer, buyout, subscription) to `whatsub-license`, with zero behavior change to existing gates.

**Architecture:** A new email-keyed `ios_entitlements` table (there is no `users` table — email is the account identity, same as `licenses`/`orders`). New `Database` methods read/write it. A new `routes/iap.ts` exposes `POST /api/iap/verify` (client reports a StoreKit-verified transaction) and `POST /api/iap/notifications` (Apple App Store Server Notifications V2), both depending on an **injectable verifier interface** so the route logic is unit-testable with a fake (the real Apple JWS verification lands in Phase 2 where sandbox transactions exercise it). `GET /api/auth/me` is extended to lazily start the trial and return the iOS entitlement fields.

**Tech Stack:** TypeScript, Hono, node-postgres, pg-mem (tests), Vitest. BIGINT timestamps are unix-ms `number` (db.ts sets `pg.types.setTypeParser(20, Number)`).

**Scope guard — Phase 1 is purely additive:**
- **Does NOT** change `quotaLimit` in `routes/library.ts` (stays `hasActiveLicense ? 50 : 3` — flips to `iosSubActive ? 50 : 3` in Phase 3).
- **Does NOT** change corpus gating (`requireActiveLicense`) — that broadens to `hasLicense || iosBuyout || trialActive` in Phase 2 with the iOS wall.
- **Does NOT** implement real Apple JWS verification — `index.ts` mounts `iapRoute(db, null)` so the endpoints return `503 verifier_not_configured` until Phase 2 wires `@apple/app-store-server-library`. Nothing calls these endpoints until the iOS app ships (Phase 2), so this is safe.

**Branch:** `feat/ios-entitlements` off `main`. Run all tests with `pnpm test` (alias for `vitest run`); typecheck with `pnpm typecheck`.

---

## Shared interfaces (locked — used across tasks; keep names identical)

Defined in `src/lib/db.ts` (the type) and `src/routes/iap.ts` (the verifier):

```ts
// src/lib/db.ts — near the other exported types
export interface IosEntitlements {
  iosBuyout: boolean;
  iosSubActive: boolean;
  subProductId: string | null;
  trialStartedAt: number | null;
  trialExpiresAt: number | null;   // trialStartedAt + 24h, or null if no trial row
}
```

```ts
// src/routes/iap.ts
export interface VerifiedTransaction {
  productId: string;
  originalTransactionId: string;
  kind: 'buyout' | 'subscription';
  expiresDate?: number;            // unix ms; present for subscriptions
}
export interface VerifiedNotification {
  notificationType: string;        // SUBSCRIBED | DID_RENEW | EXPIRED | REFUND | ...
  productId: string;
  originalTransactionId: string;
  kind: 'buyout' | 'subscription';
  expiresDate?: number;            // unix ms; present for subscription renewals
}
export interface IapVerifier {
  verifyTransaction(signedTransactionInfo: string): Promise<VerifiedTransaction>;
  verifyNotification(signedPayload: string): Promise<VerifiedNotification>;
}
```

Database method signatures (added to `class Database`, before its closing `}` at end of `src/lib/db.ts`):

```ts
ensureTrialStarted(email: string, now: number): Promise<void>;
getIosEntitlements(email: string, now: number): Promise<IosEntitlements>;
grantBuyout(email: string, txnId: string, now: number): Promise<void>;
revokeBuyout(txnId: string, now: number): Promise<void>;
setSubscription(email: string, expiresAt: number, productId: string, txnId: string, now: number): Promise<void>;
extendSubscription(txnId: string, expiresAt: number, productId: string, now: number): Promise<void>;
expireSubscription(txnId: string, now: number): Promise<void>;
```

Product ID constants (in `src/routes/iap.ts`): `BUYOUT_PRODUCT_ID = 'cc.eversay.whatsub.mobile.fullunlock'`; subscriptions `'whatsub_pro_month'`, `'whatsub_pro_year'`.

---

## Task 1: Schema + trial timer + entitlement read

**Files:**
- Modify: `schema.sql` (append new table)
- Modify: `src/lib/db.ts` (add `IosEntitlements` type + `IOS_TRIAL_MS` const + `ensureTrialStarted` + `getIosEntitlements`)
- Test: `tests/ios-entitlements-db.test.ts` (create)

- [ ] **Step 1: Append the table to `schema.sql`** (after the `import_queue` block at the end)

```sql

-- iOS in-app-purchase entitlements (added 2026-05-24). Email-keyed — there is
-- no users table; email is the account identity (same as licenses/orders).
-- One row per account, created lazily on first authed /me (ensureTrialStarted).
--   trial_started_at : unix ms of first app contact; trial = now < trial_started_at + 24h
--   buyout_*         : non-consumable "fullunlock" — buyout_at non-null = owns it forever
--   sub_*            : auto-renewable subscription — sub_expires_at > now = active
--   *_txn_id         : Apple originalTransactionId, so ASSN webhooks (which carry only
--                      originalTransactionId, not email) map back to the right account.
CREATE TABLE IF NOT EXISTS ios_entitlements (
    email             TEXT     PRIMARY KEY,
    trial_started_at  BIGINT,
    buyout_at         BIGINT,
    buyout_txn_id     TEXT,
    sub_expires_at    BIGINT,
    sub_product_id    TEXT,
    sub_txn_id        TEXT,
    updated_at        BIGINT   NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_ios_ent_buyout_txn ON ios_entitlements (buyout_txn_id);
CREATE INDEX IF NOT EXISTS idx_ios_ent_sub_txn    ON ios_entitlements (sub_txn_id);
```

- [ ] **Step 2: Write the failing test** — create `tests/ios-entitlements-db.test.ts`

```ts
import { describe, it, expect } from 'vitest';
import { newDb, type IMemoryDb } from 'pg-mem';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Database } from '../src/lib/db.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

function makeDb(): { db: Database; mem: IMemoryDb } {
  const mem = newDb();
  const sql = readFileSync(join(__dirname, '..', 'schema.sql'), 'utf-8');
  mem.public.none(sql);
  const adapter = mem.adapters.createPg();
  return { db: new Database(new adapter.Pool()), mem };
}

const DAY = 24 * 60 * 60 * 1000;

describe('ios entitlements: trial', () => {
  it('getIosEntitlements returns all-empty for an unknown account', async () => {
    const { db } = makeDb();
    const ent = await db.getIosEntitlements('nobody@x.com', 1000);
    expect(ent).toEqual({
      iosBuyout: false, iosSubActive: false, subProductId: null,
      trialStartedAt: null, trialExpiresAt: null,
    });
  });

  it('ensureTrialStarted records the start once; repeat is a no-op', async () => {
    const { db } = makeDb();
    await db.ensureTrialStarted('a@x.com', 1000);
    await db.ensureTrialStarted('a@x.com', 9999);          // must NOT overwrite
    const ent = await db.getIosEntitlements('a@x.com', 1000);
    expect(ent.trialStartedAt).toBe(1000);
    expect(ent.trialExpiresAt).toBe(1000 + DAY);
  });

  it('trial is active before expiry and inactive after (caller derives from trialExpiresAt)', async () => {
    const { db } = makeDb();
    await db.ensureTrialStarted('a@x.com', 1000);
    const ent = await db.getIosEntitlements('a@x.com', 1000);
    expect(1000 < ent.trialExpiresAt!).toBe(true);
    expect(1000 + DAY + 1 < ent.trialExpiresAt!).toBe(false);
  });
});
```

- [ ] **Step 3: Run it — expect FAIL**

Run: `pnpm test ios-entitlements-db`
Expected: FAIL (`db.getIosEntitlements is not a function` / `db.ensureTrialStarted is not a function`).

- [ ] **Step 4: Implement** — in `src/lib/db.ts`

Add the type + const near the top exported types (after the existing `interface RawContributionRow` block is fine, or beside other exported interfaces):

```ts
export interface IosEntitlements {
  iosBuyout: boolean;
  iosSubActive: boolean;
  subProductId: string | null;
  trialStartedAt: number | null;
  trialExpiresAt: number | null;
}

const IOS_TRIAL_MS = 24 * 60 * 60 * 1000;
```

Add these two methods inside `class Database` (just before its final closing `}`):

```ts
  /** Lazily start the per-account iOS trial clock on first authed contact. Idempotent. */
  async ensureTrialStarted(email: string, now: number): Promise<void> {
    await this.pool.query(
      `INSERT INTO ios_entitlements (email, trial_started_at, updated_at)
       VALUES ($1, $2, $2)
       ON CONFLICT (email) DO NOTHING`,
      [email, now],
    );
  }

  /** Resolve an account's iOS entitlement state. `now` is used to compute sub-active. */
  async getIosEntitlements(email: string, now: number): Promise<IosEntitlements> {
    const res = await this.pool.query<{
      trial_started_at: number | null;
      buyout_at: number | null;
      sub_expires_at: number | null;
      sub_product_id: string | null;
    }>(
      `SELECT trial_started_at, buyout_at, sub_expires_at, sub_product_id
         FROM ios_entitlements WHERE email = $1 LIMIT 1`,
      [email],
    );
    const row = res.rows[0];
    const trialStartedAt = row?.trial_started_at ?? null;
    return {
      iosBuyout: row?.buyout_at != null,
      iosSubActive: row?.sub_expires_at != null && row.sub_expires_at > now,
      subProductId: row?.sub_product_id ?? null,
      trialStartedAt,
      trialExpiresAt: trialStartedAt != null ? trialStartedAt + IOS_TRIAL_MS : null,
    };
  }
```

- [ ] **Step 5: Run it — expect PASS**

Run: `pnpm test ios-entitlements-db`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add schema.sql src/lib/db.ts tests/ios-entitlements-db.test.ts
git commit -m "feat(iap): ios_entitlements table + trial timer (ensureTrialStarted/getIosEntitlements)"
```

---

## Task 2: Buyout grant + revoke

**Files:**
- Modify: `src/lib/db.ts` (add `grantBuyout`, `revokeBuyout`)
- Test: `tests/ios-entitlements-db.test.ts` (add a `describe` block)

- [ ] **Step 1: Add the failing tests** (append to `tests/ios-entitlements-db.test.ts`)

```ts
describe('ios entitlements: buyout', () => {
  it('grantBuyout makes iosBuyout true; preserves an existing trial row', async () => {
    const { db } = makeDb();
    await db.ensureTrialStarted('a@x.com', 1000);
    await db.grantBuyout('a@x.com', 'OTXN-BUY-1', 2000);
    const ent = await db.getIosEntitlements('a@x.com', 3000);
    expect(ent.iosBuyout).toBe(true);
    expect(ent.trialStartedAt).toBe(1000);               // not clobbered
  });

  it('grantBuyout works even with no prior trial row (upsert)', async () => {
    const { db } = makeDb();
    await db.grantBuyout('fresh@x.com', 'OTXN-BUY-2', 2000);
    expect((await db.getIosEntitlements('fresh@x.com', 3000)).iosBuyout).toBe(true);
  });

  it('revokeBuyout (refund) clears the buyout, matched by original transaction id', async () => {
    const { db } = makeDb();
    await db.grantBuyout('a@x.com', 'OTXN-BUY-1', 2000);
    await db.revokeBuyout('OTXN-BUY-1', 4000);
    expect((await db.getIosEntitlements('a@x.com', 5000)).iosBuyout).toBe(false);
  });

  it('revokeBuyout with an unknown txn id touches nothing', async () => {
    const { db } = makeDb();
    await db.grantBuyout('a@x.com', 'OTXN-BUY-1', 2000);
    await db.revokeBuyout('OTXN-UNKNOWN', 4000);
    expect((await db.getIosEntitlements('a@x.com', 5000)).iosBuyout).toBe(true);
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (`db.grantBuyout is not a function`)

Run: `pnpm test ios-entitlements-db`

- [ ] **Step 3: Implement** — add to `class Database` (after `getIosEntitlements`)

```ts
  /** Grant the permanent non-consumable buyout. Records the originalTransactionId
   *  so a later REFUND notification can map back to this account. */
  async grantBuyout(email: string, txnId: string, now: number): Promise<void> {
    await this.pool.query(
      `INSERT INTO ios_entitlements (email, buyout_at, buyout_txn_id, updated_at)
       VALUES ($1, $2, $3, $2)
       ON CONFLICT (email) DO UPDATE
         SET buyout_at = $2, buyout_txn_id = $3, updated_at = $2`,
      [email, now, txnId],
    );
  }

  /** Revoke the buyout on refund. Matched by originalTransactionId (ASSN has no email). */
  async revokeBuyout(txnId: string, now: number): Promise<void> {
    await this.pool.query(
      `UPDATE ios_entitlements SET buyout_at = NULL, updated_at = $2 WHERE buyout_txn_id = $1`,
      [txnId, now],
    );
  }
```

- [ ] **Step 4: Run — expect PASS**

Run: `pnpm test ios-entitlements-db`

- [ ] **Step 5: Commit**

```bash
git add src/lib/db.ts tests/ios-entitlements-db.test.ts
git commit -m "feat(iap): buyout grant/revoke db methods"
```

---

## Task 3: Subscription set / renew / expire

**Files:**
- Modify: `src/lib/db.ts` (add `setSubscription`, `extendSubscription`, `expireSubscription`)
- Test: `tests/ios-entitlements-db.test.ts` (add a `describe` block)

- [ ] **Step 1: Add the failing tests** (append)

```ts
describe('ios entitlements: subscription', () => {
  it('setSubscription makes iosSubActive true while now < expiry', async () => {
    const { db } = makeDb();
    await db.setSubscription('a@x.com', 10_000, 'whatsub_pro_month', 'OTXN-SUB-1', 1000);
    const active = await db.getIosEntitlements('a@x.com', 5000);
    expect(active.iosSubActive).toBe(true);
    expect(active.subProductId).toBe('whatsub_pro_month');
    const lapsed = await db.getIosEntitlements('a@x.com', 20_000);
    expect(lapsed.iosSubActive).toBe(false);             // past expiry
  });

  it('extendSubscription (renewal) pushes expiry out, matched by txn id', async () => {
    const { db } = makeDb();
    await db.setSubscription('a@x.com', 10_000, 'whatsub_pro_month', 'OTXN-SUB-1', 1000);
    await db.extendSubscription('OTXN-SUB-1', 40_000, 'whatsub_pro_month', 11_000);
    expect((await db.getIosEntitlements('a@x.com', 30_000)).iosSubActive).toBe(true);
  });

  it('expireSubscription (EXPIRED/REFUND) deactivates immediately, matched by txn id', async () => {
    const { db } = makeDb();
    await db.setSubscription('a@x.com', 10_000, 'whatsub_pro_month', 'OTXN-SUB-1', 1000);
    await db.expireSubscription('OTXN-SUB-1', 6000);
    expect((await db.getIosEntitlements('a@x.com', 6001)).iosSubActive).toBe(false);
  });

  it('buyout and subscription coexist independently on one account', async () => {
    const { db } = makeDb();
    await db.grantBuyout('a@x.com', 'OTXN-BUY-1', 1000);
    await db.setSubscription('a@x.com', 10_000, 'whatsub_pro_year', 'OTXN-SUB-1', 1000);
    const ent = await db.getIosEntitlements('a@x.com', 5000);
    expect(ent.iosBuyout).toBe(true);
    expect(ent.iosSubActive).toBe(true);
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

Run: `pnpm test ios-entitlements-db`

- [ ] **Step 3: Implement** — add to `class Database`

```ts
  /** Initial subscription grant (from POST /verify, where we know the email). */
  async setSubscription(
    email: string, expiresAt: number, productId: string, txnId: string, now: number,
  ): Promise<void> {
    await this.pool.query(
      `INSERT INTO ios_entitlements (email, sub_expires_at, sub_product_id, sub_txn_id, updated_at)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (email) DO UPDATE
         SET sub_expires_at = $2, sub_product_id = $3, sub_txn_id = $4, updated_at = $5`,
      [email, expiresAt, productId, txnId, now],
    );
  }

  /** Renewal (from ASSN DID_RENEW etc). Matched by originalTransactionId. Matches
   *  zero rows if /verify never ran for this txn — harmless (initial grant is /verify's job). */
  async extendSubscription(
    txnId: string, expiresAt: number, productId: string, now: number,
  ): Promise<void> {
    await this.pool.query(
      `UPDATE ios_entitlements
          SET sub_expires_at = $2, sub_product_id = $3, updated_at = $4
        WHERE sub_txn_id = $1`,
      [txnId, expiresAt, productId, now],
    );
  }

  /** Expire/refund a subscription immediately (from ASSN EXPIRED/REFUND). By txn id. */
  async expireSubscription(txnId: string, now: number): Promise<void> {
    await this.pool.query(
      `UPDATE ios_entitlements SET sub_expires_at = $2, updated_at = $2 WHERE sub_txn_id = $1`,
      [txnId, now],
    );
  }
```

> Note: `expireSubscription` sets `sub_expires_at = now`, so `getIosEntitlements(_, t)` with `t >= now` reports inactive.

- [ ] **Step 4: Run — expect PASS**

Run: `pnpm test ios-entitlements-db`

- [ ] **Step 5: Commit**

```bash
git add src/lib/db.ts tests/ios-entitlements-db.test.ts
git commit -m "feat(iap): subscription set/extend/expire db methods"
```

---

## Task 4: Extend `GET /api/auth/me`

**Files:**
- Modify: `src/routes/auth.ts` (the `/me` handler, lines ~84-95)
- Test: `tests/auth-routes.test.ts` (update the existing `GET /api/auth/me` block)

- [ ] **Step 1: Update the existing `/me` test** in `tests/auth-routes.test.ts`

Replace the body of the first `it` under `describe('GET /api/auth/me', ...)` (currently asserts `toEqual({ email, hasActiveLicense:false, isAdmin:false })`) with:

```ts
  it('returns email + license + iOS entitlement fields, and starts the trial', async () => {
    const { app, db } = makeFullAuthApp();
    const { hashToken } = await import('../src/lib/sessionTokens.js');
    const raw = 'me-token-' + 'x'.repeat(34);
    await db.insertSessionToken({
      tokenHash: hashToken(raw), email: 'me@x.com',
      issuedAt: 1, expiresAt: Date.now() + 60_000,
    });
    const res = await app.request('/api/auth/me', {
      headers: { Authorization: `Bearer ${raw}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.email).toBe('me@x.com');
    expect(body.hasActiveLicense).toBe(false);
    expect(body.isAdmin).toBe(false);
    expect(body.iosBuyout).toBe(false);
    expect(body.iosSubActive).toBe(false);
    expect(body.subProductId).toBeNull();
    // /me lazily started the trial → expiry is ~24h out.
    expect(typeof body.trialExpiresAt).toBe('number');
    expect(body.trialExpiresAt as number).toBeGreaterThan(Date.now());

    // Idempotent: a second /me does not move the trial start.
    const first = body.trialExpiresAt as number;
    const res2 = await app.request('/api/auth/me', { headers: { Authorization: `Bearer ${raw}` } });
    expect(((await res2.json()) as Record<string, unknown>).trialExpiresAt).toBe(first);
  });
```

- [ ] **Step 2: Run — expect FAIL** (body has no `iosBuyout` yet)

Run: `pnpm test auth-routes`

- [ ] **Step 3: Implement** — replace the `/me` handler in `src/routes/auth.ts`

```ts
  // Both /me and /logout require an active session.
  app.get('/me', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    const now = Date.now();
    // Lazily start the iOS trial on first authed contact (idempotent).
    await db.ensureTrialStarted(email, now);
    const isAdmin = await db.isAdminEmail(email);
    const ios = await db.getIosEntitlements(email, now);
    return c.json({
      email,
      hasActiveLicense: c.get('hasActiveLicense' as never),
      isAdmin,
      iosBuyout: ios.iosBuyout,
      iosSubActive: ios.iosSubActive,
      subProductId: ios.subProductId,
      trialExpiresAt: ios.trialExpiresAt,
    });
  });
```

- [ ] **Step 4: Run — expect PASS**

Run: `pnpm test auth-routes`

- [ ] **Step 5: Commit**

```bash
git add src/routes/auth.ts tests/auth-routes.test.ts
git commit -m "feat(iap): /me starts trial + returns iOS entitlement fields"
```

---

## Task 5: `routes/iap.ts` — verify + notifications (injectable verifier)

**Files:**
- Create: `src/routes/iap.ts`
- Test: `tests/iap-routes.test.ts` (create)

- [ ] **Step 1: Write the failing test** — create `tests/iap-routes.test.ts`

```ts
import { describe, it, expect } from 'vitest';
import { newDb } from 'pg-mem';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Hono } from 'hono';
import { Database } from '../src/lib/db.js';
import { iapRoute, type IapVerifier, type VerifiedTransaction, type VerifiedNotification } from '../src/routes/iap.js';
import { hashToken } from '../src/lib/sessionTokens.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

function makeDb() {
  const mem = newDb();
  mem.public.none(readFileSync(join(__dirname, '..', 'schema.sql'), 'utf-8'));
  return new Database(new (mem.adapters.createPg()).Pool());
}

// A fake verifier whose decoded output is fully controlled by the test.
function fakeVerifier(over: Partial<{ tx: VerifiedTransaction; note: VerifiedNotification; throws: boolean }>): IapVerifier {
  return {
    async verifyTransaction() {
      if (over.throws) throw new Error('bad sig');
      return over.tx ?? { productId: 'cc.eversay.whatsub.mobile.fullunlock', originalTransactionId: 'T1', kind: 'buyout' };
    },
    async verifyNotification() {
      if (over.throws) throw new Error('bad sig');
      return over.note ?? { notificationType: 'EXPIRED', productId: 'whatsub_pro_month', originalTransactionId: 'T1', kind: 'subscription' };
    },
  };
}

async function authed(db: Database, email: string): Promise<string> {
  const raw = 'tok-' + 'y'.repeat(40);
  await db.insertSessionToken({ tokenHash: hashToken(raw), email, issuedAt: 1, expiresAt: Date.now() + 60_000 });
  return raw;
}

function mount(db: Database, verifier: IapVerifier | null) {
  const app = new Hono();
  app.route('/api/iap', iapRoute(db, verifier));
  return app;
}

describe('POST /api/iap/verify', () => {
  it('401 without session', async () => {
    const db = makeDb();
    const res = await mount(db, fakeVerifier({})).request('/api/iap/verify', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ signedTransactionInfo: 'jws' }),
    });
    expect(res.status).toBe(401);
  });

  it('503 when verifier is not configured', async () => {
    const db = makeDb();
    const raw = await authed(db, 'a@x.com');
    const res = await mount(db, null).request('/api/iap/verify', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${raw}` },
      body: JSON.stringify({ signedTransactionInfo: 'jws' }),
    });
    expect(res.status).toBe(503);
  });

  it('grants the buyout and returns entitlements', async () => {
    const db = makeDb();
    const raw = await authed(db, 'a@x.com');
    const v = fakeVerifier({ tx: { productId: 'cc.eversay.whatsub.mobile.fullunlock', originalTransactionId: 'BUY1', kind: 'buyout' } });
    const res = await mount(db, v).request('/api/iap/verify', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${raw}` },
      body: JSON.stringify({ signedTransactionInfo: 'jws' }),
    });
    expect(res.status).toBe(200);
    expect((await res.json() as Record<string, unknown>).iosBuyout).toBe(true);
    expect(await db.getIosEntitlements('a@x.com', Date.now())).toMatchObject({ iosBuyout: true });
  });

  it('records a subscription with its expiry', async () => {
    const db = makeDb();
    const raw = await authed(db, 'a@x.com');
    const v = fakeVerifier({ tx: { productId: 'whatsub_pro_month', originalTransactionId: 'SUB1', kind: 'subscription', expiresDate: Date.now() + 86_400_000 } });
    const res = await mount(db, v).request('/api/iap/verify', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${raw}` },
      body: JSON.stringify({ signedTransactionInfo: 'jws' }),
    });
    expect(res.status).toBe(200);
    expect((await res.json() as Record<string, unknown>).iosSubActive).toBe(true);
  });

  it('400 when verification throws', async () => {
    const db = makeDb();
    const raw = await authed(db, 'a@x.com');
    const res = await mount(db, fakeVerifier({ throws: true })).request('/api/iap/verify', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${raw}` },
      body: JSON.stringify({ signedTransactionInfo: 'jws' }),
    });
    expect(res.status).toBe(400);
  });
});

describe('POST /api/iap/notifications', () => {
  it('REFUND of a buyout revokes it (no session required)', async () => {
    const db = makeDb();
    await db.grantBuyout('a@x.com', 'BUY1', 1000);
    const v = fakeVerifier({ note: { notificationType: 'REFUND', productId: 'cc.eversay.whatsub.mobile.fullunlock', originalTransactionId: 'BUY1', kind: 'buyout' } });
    const res = await mount(db, v).request('/api/iap/notifications', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ signedPayload: 'jws' }),
    });
    expect(res.status).toBe(200);
    expect((await db.getIosEntitlements('a@x.com', 2000)).iosBuyout).toBe(false);
  });

  it('EXPIRED deactivates the subscription', async () => {
    const db = makeDb();
    await db.setSubscription('a@x.com', Date.now() + 86_400_000, 'whatsub_pro_month', 'SUB1', 1000);
    const v = fakeVerifier({ note: { notificationType: 'EXPIRED', productId: 'whatsub_pro_month', originalTransactionId: 'SUB1', kind: 'subscription' } });
    const res = await mount(db, v).request('/api/iap/notifications', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ signedPayload: 'jws' }),
    });
    expect(res.status).toBe(200);
    expect((await db.getIosEntitlements('a@x.com', Date.now() + 1)).iosSubActive).toBe(false);
  });

  it('DID_RENEW extends the subscription expiry', async () => {
    const db = makeDb();
    await db.setSubscription('a@x.com', 10_000, 'whatsub_pro_month', 'SUB1', 1000);
    const v = fakeVerifier({ note: { notificationType: 'DID_RENEW', productId: 'whatsub_pro_month', originalTransactionId: 'SUB1', kind: 'subscription', expiresDate: 99_000 } });
    const res = await mount(db, v).request('/api/iap/notifications', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ signedPayload: 'jws' }),
    });
    expect(res.status).toBe(200);
    expect((await db.getIosEntitlements('a@x.com', 50_000)).iosSubActive).toBe(true);
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (`Cannot find module '../src/routes/iap.js'`)

Run: `pnpm test iap-routes`

- [ ] **Step 3: Implement** — create `src/routes/iap.ts`

```ts
import { Hono } from 'hono';
import type { Database } from '../lib/db.js';
import { requireSession } from '../lib/auth.js';

export interface VerifiedTransaction {
  productId: string;
  originalTransactionId: string;
  kind: 'buyout' | 'subscription';
  expiresDate?: number;
}
export interface VerifiedNotification {
  notificationType: string;
  productId: string;
  originalTransactionId: string;
  kind: 'buyout' | 'subscription';
  expiresDate?: number;
}
export interface IapVerifier {
  verifyTransaction(signedTransactionInfo: string): Promise<VerifiedTransaction>;
  verifyNotification(signedPayload: string): Promise<VerifiedNotification>;
}

/**
 * IAP entitlement routes.
 *
 * - POST /verify (session): the iOS app reports a StoreKit-2-verified transaction
 *   (a signed JWS). We re-verify via `verifier`, then persist the entitlement.
 * - POST /notifications (no session): Apple App Store Server Notifications V2.
 *   Apple-signed; `verifier` validates + decodes; we apply renew/expire/refund.
 *
 * `verifier` is null until Phase 2 wires the real Apple verifier — endpoints
 * then return 503. The initial grant is /verify's job; ASSN handles lifecycle.
 */
export function iapRoute(db: Database, verifier: IapVerifier | null) {
  const app = new Hono();

  app.post('/verify', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    if (!verifier) return c.json({ error: 'verifier_not_configured' }, 503);
    let body: { signedTransactionInfo?: unknown };
    try { body = await c.req.json(); } catch { return c.json({ error: 'invalid_json' }, 400); }
    const jws = typeof body.signedTransactionInfo === 'string' ? body.signedTransactionInfo.trim() : '';
    if (!jws) return c.json({ error: 'invalid_input' }, 400);

    let tx: VerifiedTransaction;
    try { tx = await verifier.verifyTransaction(jws); }
    catch { return c.json({ error: 'verification_failed' }, 400); }

    const now = Date.now();
    if (tx.kind === 'buyout') {
      await db.grantBuyout(email, tx.originalTransactionId, now);
    } else {
      await db.setSubscription(email, tx.expiresDate ?? now, tx.productId, tx.originalTransactionId, now);
    }
    const ent = await db.getIosEntitlements(email, now);
    return c.json({
      ok: true,
      hasActiveLicense: c.get('hasActiveLicense' as never),
      iosBuyout: ent.iosBuyout,
      iosSubActive: ent.iosSubActive,
      subProductId: ent.subProductId,
      trialExpiresAt: ent.trialExpiresAt,
    });
  });

  app.post('/notifications', async (c) => {
    if (!verifier) return c.json({ error: 'verifier_not_configured' }, 503);
    let body: { signedPayload?: unknown };
    try { body = await c.req.json(); } catch { return c.json({ error: 'invalid_json' }, 400); }
    const signed = typeof body.signedPayload === 'string' ? body.signedPayload.trim() : '';
    if (!signed) return c.json({ error: 'invalid_input' }, 400);

    let n: VerifiedNotification;
    try { n = await verifier.verifyNotification(signed); }
    catch { return c.json({ error: 'verification_failed' }, 400); }

    const now = Date.now();
    switch (n.notificationType) {
      case 'REFUND':
        if (n.kind === 'buyout') await db.revokeBuyout(n.originalTransactionId, now);
        else await db.expireSubscription(n.originalTransactionId, now);
        break;
      case 'EXPIRED':
        await db.expireSubscription(n.originalTransactionId, now);
        break;
      case 'SUBSCRIBED':
      case 'DID_RENEW':
      case 'DID_CHANGE_RENEWAL_STATUS':
      case 'OFFER_REDEEMED':
        if (n.kind === 'subscription' && n.expiresDate != null) {
          await db.extendSubscription(n.originalTransactionId, n.expiresDate, n.productId, now);
        }
        break;
      default:
        break;   // unknown types acknowledged with 200 (Apple retries on non-2xx)
    }
    return c.json({ ok: true });
  });

  return app;
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `pnpm test iap-routes`

- [ ] **Step 5: Commit**

```bash
git add src/routes/iap.ts tests/iap-routes.test.ts
git commit -m "feat(iap): /verify + /notifications routes with injectable verifier"
```

---

## Task 6: Mount the route + full typecheck/test

**Files:**
- Modify: `src/index.ts` (import + mount `iapRoute`)

- [ ] **Step 1: Add the import** in `src/index.ts` (beside the other route imports, ~line 19)

```ts
import { iapRoute } from './routes/iap.js';
```

- [ ] **Step 2: Mount it** — beside the other `app.route(...)` calls (e.g. just after the `/api/library` mount, ~line 82). Pass `null` (real Apple verifier lands in Phase 2):

```ts
  // IAP entitlement endpoints. verifier=null until Phase 2 wires the real
  // Apple JWS verifier (@apple/app-store-server-library) — endpoints 503 until then.
  // Nothing calls these until the iOS app ships (Phase 2), so this is safe.
  app.route('/api/iap', iapRoute(db, null));
```

- [ ] **Step 3: Typecheck + run the whole suite**

Run: `pnpm typecheck && pnpm test`
Expected: typecheck clean; all tests PASS (existing suites + the two new files).

- [ ] **Step 4: Commit**

```bash
git add src/index.ts
git commit -m "feat(iap): mount /api/iap (verifier deferred to Phase 2)"
```

---

## Integration / deploy (after all tasks — REQUIRES USER AUTHORIZATION)

Phase 1 is additive (no behavior change), but deploying still touches prod. Do NOT run without the user's go-ahead.

- [ ] Apply the schema migration on prod (idempotent — only creates `ios_entitlements` + 2 indexes):
  ```bash
  docker compose -f /opt/enghub/docker-compose.yml exec -T postgres \
    psql -U whatsub_license_user -d whatsub_license < schema.sql
  ```
- [ ] Build + ship the backend image per the project's deploy flow (build locally → push image → restart container).
- [ ] Smoke check: `GET /api/auth/me` for a session returns the new fields (`iosBuyout:false, iosSubActive:false, trialExpiresAt:<number>`); `POST /api/iap/verify` with a bearer returns `503 verifier_not_configured` (expected until Phase 2).
- [ ] Merge `feat/ios-entitlements` → `main` (backend repo `main` is deploy-tracked; confirm with user).

## Deferred to Phase 2 (not in this plan)
- Real Apple verifier: add `@apple/app-store-server-library`, build the `IapVerifier` from App Store config (bundle id `cc.eversay.whatsub.mobile`, Apple root certs, environment sandbox/prod, App Store Server API key), wire `iapRoute(db, realVerifier)`. Register the ASSN V2 webhook URL (`https://whatsub.eversay.cc/api/iap/notifications`) in App Store Connect. Exercised end-to-end via sandbox.
- Corpus gating broadens to `hasLicense || iosBuyout || trialActive`.

## Deferred to Phase 3 (not in this plan)
- `routes/library.ts` `quotaLimit` flips `hasActiveLicense ? 50 : 3` → `iosSubActive ? 50 : 3` (shipped together with the iOS subscription UI so license users don't lose 50 with no path to regain it).
