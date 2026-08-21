# LLM Entitlements and Token Wallet Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make LLM mode permissions server-authoritative and add an idempotent, concurrency-safe Pro Token wallet shared by iOS, desktop, and website.

**Architecture:** `/auth/me` exposes one normalized entitlement matrix. PostgreSQL wallet, immutable ledger, and request reservations atomically allocate monthly allowance before top-up balance; Apple and Alipay settlement credit the same wallet through one idempotent method.

**Tech Stack:** Node 20, TypeScript 5.6, Hono, PostgreSQL/pg-mem, Vitest, Apple App Store Server Library, Alipay SDK

**Spec:** `whatsub-mobile/docs/superpowers/specs/2026-08-21-llm-entitlements-and-token-topups-design.md`

## Global Constraints

- Free/trial: managed only; buyout: BYOK only; Pro: managed only; buyout + Pro: both.
- Pro includes 5,000,000 combined input/output Tokens per month.
- Top-up SKUs: `whatsub_token_1m` = 1,000,000/¥10, `whatsub_token_5m` = 5,000,000/¥45, `whatsub_token_15m` = 15,000,000/¥125.
- Top-up balance never expires, freezes without active Pro, and cannot become negative.
- Schema and wire changes remain backward-compatible and idempotent.
- Clients route by stable error code, never Chinese-message parsing.

---

### Task 1: Server-authoritative entitlement matrix

**Files:**
- Modify: `whatsub-license/src/lib/auth.ts`
- Modify: `whatsub-license/src/lib/types.ts`
- Modify: `whatsub-license/src/routes/auth.ts`
- Test: `whatsub-license/tests/auth-routes.test.ts`

**Interfaces:**
- Produces: `LlmEntitlements`, `getLlmEntitlements(db, email, now, knownHasLicense?)`
- Wire: `MeResponse.llmEntitlements`

- [ ] **Step 1: Write the failing four-state route test**

```ts
it.each([
  ['free', false, false, { tier: 'free', managedRelay: true, byok: false, tokenTopups: false }],
  ['buyout', true, false, { tier: 'buyout', managedRelay: false, byok: true, tokenTopups: false }],
  ['pro', false, true, { tier: 'pro', managedRelay: true, byok: false, tokenTopups: true }],
  ['buyout_pro', true, true, { tier: 'buyout_pro', managedRelay: true, byok: true, tokenTopups: true }],
])('%s returns coherent capabilities', async (_name, license, sub, expected) => {
  const rig = await makeAuthenticatedRig({ license, sub });
  const response = await rig.getMe();
  expect((await response.json()).llmEntitlements).toEqual(expected);
});
```

- [ ] **Step 2: Run and prove the field is absent**

Run: `npm test -- --run tests/auth-routes.test.ts`

Expected: FAIL because `llmEntitlements` is undefined.

- [ ] **Step 3: Add the domain type and resolver**

```ts
export type LlmEntitlementTier = 'free' | 'buyout' | 'pro' | 'buyout_pro';
export interface LlmEntitlements {
  tier: LlmEntitlementTier;
  managedRelay: boolean;
  byok: boolean;
  tokenTopups: boolean;
}

export async function getLlmEntitlements(
  db: Database, email: string, now: number, knownHasLicense?: boolean,
): Promise<LlmEntitlements> {
  const hasLicense = knownHasLicense ?? !!(await db.findActiveLicenseByEmail(email));
  const hasPro = await hasActiveSubscription(db, email, now);
  if (hasLicense && hasPro) return { tier: 'buyout_pro', managedRelay: true, byok: true, tokenTopups: true };
  if (hasLicense) return { tier: 'buyout', managedRelay: false, byok: true, tokenTopups: false };
  if (hasPro) return { tier: 'pro', managedRelay: true, byok: false, tokenTopups: true };
  return { tier: 'free', managedRelay: true, byok: false, tokenTopups: false };
}
```

- [ ] **Step 4: Run tests and commit**

```bash
npm test -- --run tests/auth-routes.test.ts
git add src/lib/auth.ts src/lib/types.ts src/routes/auth.ts tests/auth-routes.test.ts
git commit -m "feat(auth): expose LLM entitlements"
```

### Task 2: Wallet, ledger, and reservation database

**Files:**
- Modify: `whatsub-license/schema.sql`
- Modify: `whatsub-license/src/lib/db.ts`
- Create: `whatsub-license/tests/llm-token-wallet-db.test.ts`

**Interfaces:**
- Produces: `creditLlmTokens`, `getLlmTokenWallet`, `reserveLlmTokens`, `settleLlmTokenReservation`, `releaseLlmTokenReservation`, `reapExpiredLlmTokenReservations`

- [ ] **Step 1: Add failing idempotency and concurrency tests**

```ts
it('credits one external transaction exactly once', async () => {
  const input = { email: 'pro@x.com', source: 'apple' as const, externalTransactionId: 'A-1',
    productId: 'whatsub_token_1m', tokens: 1_000_000, amountCny: null, createdAt: 100 };
  expect(await db.creditLlmTokens(input)).toMatchObject({ credited: true, balance: 1_000_000 });
  expect(await db.creditLlmTokens(input)).toMatchObject({ credited: false, balance: 1_000_000 });
});

it('does not oversell concurrent reservations', async () => {
  await seedWallet(db, 'pro@x.com', 1_000);
  const results = await Promise.all(['r1', 'r2'].map(requestId => db.reserveLlmTokens({
    requestId, email: 'pro@x.com', periodMonth: '2026-08', monthlyLimit: 0,
    maxTokens: 700, expiresAt: 10_000,
  })));
  expect(results.filter(Boolean)).toHaveLength(1);
});
```

- [ ] **Step 2: Run and prove tables/methods are missing**

Run: `npm test -- --run tests/llm-token-wallet-db.test.ts tests/schema.test.ts`

- [ ] **Step 3: Add idempotent schema**

```sql
CREATE TABLE IF NOT EXISTS llm_token_wallets (
  email TEXT PRIMARY KEY,
  balance_tokens BIGINT NOT NULL DEFAULT 0 CHECK (balance_tokens >= 0),
  reserved_tokens BIGINT NOT NULL DEFAULT 0 CHECK (reserved_tokens >= 0),
  updated_at BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS llm_token_transactions (
  id BIGSERIAL PRIMARY KEY, email TEXT NOT NULL, source TEXT NOT NULL,
  external_transaction_id TEXT NOT NULL, product_id TEXT, token_delta BIGINT NOT NULL,
  amount_cny NUMERIC(10,2), created_at BIGINT NOT NULL, metadata JSONB,
  UNIQUE (source, external_transaction_id)
);
CREATE TABLE IF NOT EXISTS llm_token_reservations (
  request_id TEXT PRIMARY KEY, email TEXT NOT NULL, period_month TEXT NOT NULL,
  monthly_reserved BIGINT NOT NULL, topup_reserved BIGINT NOT NULL,
  settled_tokens BIGINT, status TEXT NOT NULL, expires_at BIGINT NOT NULL, created_at BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS llm_token_refund_reviews (
  id BIGSERIAL PRIMARY KEY, source TEXT NOT NULL, external_transaction_id TEXT NOT NULL,
  email TEXT NOT NULL, requested_token_reversal BIGINT NOT NULL, reason TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending', created_at BIGINT NOT NULL,
  resolved_at BIGINT, resolved_by TEXT, resolution_note TEXT,
  UNIQUE (source, external_transaction_id)
);
```

- [ ] **Step 4: Implement atomic methods**

Use a transaction and `SELECT balance_tokens, reserved_tokens FROM llm_token_wallets WHERE email = $1 FOR UPDATE`. Monthly availability equals limit minus settled usage minus active monthly reservations. Wallet availability equals balance minus active reservations.

```ts
async settleLlmTokenReservation(input: {
  requestId: string; actualInputTokens: number; actualOutputTokens: number; settledAt: number;
}): Promise<{ monthlyCharged: number; topupCharged: number; topupBalance: number }>;
```

Settlement updates `llm_usage`, deducts actual overflow from the wallet, releases unused reservation, and marks the reservation settled in one transaction.

- [ ] **Step 5: Add release, expiry, and monthly-first tests**

```ts
it('release restores all reserved capacity without charging usage', async () => {
  await seedWallet(db, 'pro@x.com', 1_000);
  await reserve(db, { requestId: 'release-1', monthlyLimit: 0, maxTokens: 700 });
  expect(await db.releaseLlmTokenReservation('release-1', 200)).toBe(true);
  expect(await db.getLlmTokenWallet('pro@x.com')).toMatchObject({ balance: 1_000, reserved: 0 });
});
it('settlement charges monthly allowance before wallet balance', async () => {
  await seedMonthlyUsage(db, 'pro@x.com', 900);
  await seedWallet(db, 'pro@x.com', 1_000);
  await reserve(db, { requestId: 'settle-1', monthlyLimit: 1_000, maxTokens: 200 });
  expect(await db.settleLlmTokenReservation({ requestId: 'settle-1', actualInputTokens: 100,
    actualOutputTokens: 50, settledAt: 200 })).toMatchObject({ monthlyCharged: 100, topupCharged: 50, topupBalance: 950 });
});
it('reaping the same expired reservation twice is idempotent', async () => {
  await seedWallet(db, 'pro@x.com', 1_000);
  await reserve(db, { requestId: 'expired-1', monthlyLimit: 0, maxTokens: 700, expiresAt: 100 });
  expect(await db.reapExpiredLlmTokenReservations(101)).toBe(1);
  expect(await db.reapExpiredLlmTokenReservations(102)).toBe(0);
});
```

- [ ] **Step 6: Run tests and commit**

```bash
npm test -- --run tests/llm-token-wallet-db.test.ts tests/schema.test.ts
git add schema.sql src/lib/db.ts tests/llm-token-wallet-db.test.ts tests/schema.test.ts
git commit -m "feat(llm): add token wallet ledger"
```

### Task 3: Product catalog and owner-only wallet routes

**Files:**
- Create: `whatsub-license/src/lib/tokenTopupProducts.ts`
- Create: `whatsub-license/src/routes/tokenTopups.ts`
- Modify: `whatsub-license/src/index.ts`
- Create: `whatsub-license/tests/token-topup-routes.test.ts`

**Interfaces:**
- Produces: `TOKEN_TOPUP_PRODUCTS`, catalog, wallet, and transaction-history routes

- [ ] **Step 1: Write failing catalog/privacy tests**

```ts
it('returns three server-priced products', async () => {
  const res = await app.request('/api/llm/topups/catalog');
  expect((await res.json()).products.map((x: any) => [x.id, x.tokens, x.priceCny])).toEqual([
    ['whatsub_token_1m', 1_000_000, '10.00'],
    ['whatsub_token_5m', 5_000_000, '45.00'],
    ['whatsub_token_15m', 15_000_000, '125.00'],
  ]);
});
it('does not expose a wallet without owner auth', async () => {
  expect((await app.request('/api/llm/topups/wallet')).status).toBe(401);
});
```

- [ ] **Step 2: Run, implement, rerun**

Run: `npm test -- --run tests/token-topup-routes.test.ts`

Wallet returns `monthlyUsed`, `monthlyLimit`, `topupBalance`, `topupFrozen`, `periodResetAt`; history is owner-filtered and capped at 50.

- [ ] **Step 3: Commit**

```bash
git add src/lib/tokenTopupProducts.ts src/routes/tokenTopups.ts src/index.ts tests/token-topup-routes.test.ts
git commit -m "feat(llm): expose token topup catalog"
```

### Task 4: Reserve and settle managed relay requests

**Files:**
- Modify: `whatsub-license/src/routes/llm.ts`
- Modify: `whatsub-license/tests/llm-routes.test.ts`

**Interfaces:**
- Consumes: Task 2 reservation methods
- Produces: wallet-aware `quota_exceeded`

- [ ] **Step 1: Add failing boundary tests**

```ts
it('uses wallet only after monthly allowance', async () => {
  const rig = await makeProRig({ monthlyUsed: 4_999_900, topupBalance: 1_000 });
  expect((await postChat(rig.app, rig.token, { messages: MSGS, max_tokens: 200 })).status).toBe(200);
  expect((await rig.wallet()).balance).toBeLessThan(1_000);
});
it('rejects before upstream when neither source can reserve', async () => {
  const rig = await makeProRig({ monthlyUsed: 5_000_000, topupBalance: 0 });
  expect((await postChat(rig.app, rig.token, { messages: MSGS })).status).toBe(429);
  expect(rig.upstream).not.toHaveBeenCalled();
});
```

- [ ] **Step 2: Replace Pro's non-atomic pre-check**

Reserve `estimatedInput + sanitizedMaxOutput` before admission. Settle with upstream usage; release on admission rejection, upstream failure, and cancellation. Free/trial remain lifetime-budgeted and never consume wallet balance.

- [ ] **Step 3: Run quota/abort tests and commit**

```bash
npm test -- --run tests/llm-routes.test.ts
git add src/routes/llm.ts tests/llm-routes.test.ts
git commit -m "feat(llm): settle Pro usage against topups"
```

### Task 5: Resume mobile jobs after capacity returns

**Files:**
- Modify: `whatsub-license/src/routes/mobileAnalysis.ts`
- Modify: `whatsub-license/tests/mobile-analysis-routes.test.ts`

- [ ] **Step 1: Add failing checkpoint resume test**

```ts
it('resumes a quota-paused job after credit without replaying durable cues', async () => {
  const rig = await makePausedQuotaJob({ completedCues: 73, totalCues: 150 });
  await rig.credit(1_000_000);
  expect((await rig.resume()).status).toBe(200);
  expect(rig.firstRequestedCue()).toBe(73);
});
```

- [ ] **Step 2: Make resume use wallet-aware preflight**

Keep attempt UUID, provisional Library entry, durable cue cursor, and stored result rows. Successful preflight changes only `paused_quota` to queued.

- [ ] **Step 3: Run and commit**

```bash
npm test -- --run tests/mobile-analysis-routes.test.ts tests/mobile-analysis-db.test.ts
git add src/routes/mobileAnalysis.ts tests/mobile-analysis-routes.test.ts
git commit -m "feat(analysis): resume jobs after token topup"
```

### Task 6: Credit Apple consumables

**Files:**
- Modify: `whatsub-license/src/lib/appleVerifier.ts`
- Modify: `whatsub-license/src/routes/iap.ts`
- Modify: `whatsub-license/tests/apple-verifier.test.ts`
- Modify: `whatsub-license/tests/iap-routes.test.ts`

- [ ] **Step 1: Add failing redelivery test**

```ts
it('credits a verified consumable once', async () => {
  const verifier = fakeVerifier({ productId: 'whatsub_token_1m', transactionId: 'TX-1', kind: 'token_topup' });
  expect(await json(await verify(app, verifier, session))).toMatchObject({ credited: true, topupBalance: 1_000_000 });
  expect(await json(await verify(app, verifier, session))).toMatchObject({ credited: false, topupBalance: 1_000_000 });
});
```

- [ ] **Step 2: Implement product classification and account binding**

Require a valid session and matching `appAccountToken`. A valid transaction still credits if Pro expires between Apple purchase and verification, returning `topupFrozen: true`.

- [ ] **Step 3: Run and commit**

```bash
npm test -- --run tests/apple-verifier.test.ts tests/iap-routes.test.ts
git add src/lib/appleVerifier.ts src/routes/iap.ts tests/apple-verifier.test.ts tests/iap-routes.test.ts
git commit -m "feat(iap): credit token consumables"
```

### Task 7: Add authenticated Alipay top-up orders

**Files:**
- Modify: `whatsub-license/src/routes/payment.ts`
- Modify: `whatsub-license/src/lib/db.ts`
- Modify: `whatsub-license/tests/payment.test.ts`

- [ ] **Step 1: Add failing Pro gate and duplicate settlement tests**

```ts
it('requires active Pro for a token order', async () => {
  const res = await createOrder(app, freeSession, { product: 'whatsub_token_1m' });
  expect(res.status).toBe(403);
  expect(await res.json()).toMatchObject({ error: 'topup_requires_pro' });
});
it('notify and query credit one wallet transaction', async () => {
  const order = await createTopupOrder(app, proSession, 'whatsub_token_5m');
  await notifyPaid(app, order.outTradeNo, 'ALI-5M-1');
  await queryPaid(app, order.outTradeNo, 'ALI-5M-1');
  expect((await db.getLlmTokenWallet('pro@x.com')).balance).toBe(5_000_000);
});
```

- [ ] **Step 2: Implement server-priced order creation and atomic settlement**

Require bearer session and active Pro at order creation. Derive amount and subject from `TOKEN_TOPUP_PRODUCTS`. Paid notify/query calls the idempotent credit method and marks the order paid atomically.

- [ ] **Step 3: Run and commit**

```bash
npm test -- --run tests/payment.test.ts
git add src/routes/payment.ts src/lib/db.ts tests/payment.test.ts
git commit -m "feat(payment): sell Pro token topups"
```

### Task 8: Refund safety and manual review

**Files:**
- Modify: `whatsub-license/src/routes/iap.ts`
- Modify: `whatsub-license/src/routes/admin.ts`
- Modify: `whatsub-license/src/lib/db.ts`
- Modify: `whatsub-license/tests/iap-routes.test.ts`
- Create: `whatsub-license/tests/admin-token-refunds.test.ts`

- [ ] **Step 1: Write failing refund tests**

```ts
it('reverses an unspent refunded pack without making balance negative', async () => {
  await creditApplePack(db, 'pro@x.com', 'TX-REFUND-1', 1_000_000);
  await deliverAppleRefund(app, 'TX-REFUND-1');
  expect((await db.getLlmTokenWallet('pro@x.com')).balance).toBe(0);
});
it('queues manual review when the refunded pack has been consumed', async () => {
  await creditApplePack(db, 'pro@x.com', 'TX-REFUND-2', 1_000_000);
  await consumeWallet(db, 'pro@x.com', 900_000);
  await deliverAppleRefund(app, 'TX-REFUND-2');
  expect(await db.listPendingLlmTokenRefundReviews()).toHaveLength(1);
  expect((await db.getLlmTokenWallet('pro@x.com')).balance).toBe(100_000);
});
```

- [ ] **Step 2: Implement safe reversal and admin resolution**

If current balance covers the whole pack, write one negative immutable transaction and debit atomically. Otherwise leave balance unchanged and create one idempotent pending review. Add authenticated admin list/resolve routes; resolution records operator, timestamp, and note and never permits a negative balance.

- [ ] **Step 3: Run and commit**

```bash
npm test -- --run tests/iap-routes.test.ts tests/admin-token-refunds.test.ts
git add src/routes/iap.ts src/routes/admin.ts src/lib/db.ts tests/iap-routes.test.ts tests/admin-token-refunds.test.ts
git commit -m "feat(admin): review consumed token refunds"
```

### Task 9: Verification and disabled-first deployment

**Files:**
- Modify: `whatsub-license/AGENTS.md`
- Modify: `whatsub-license/.env.example`

- [ ] **Step 1: Add `LLM_TOKEN_TOPUPS_ENABLED=false`**

When disabled, catalog is empty and new orders return `topup_product_invalid`; IAP verification remains able to credit a valid already-completed transaction.

- [ ] **Step 2: Run verification**

```bash
npm test -- --run tests/auth-routes.test.ts tests/llm-token-wallet-db.test.ts tests/token-topup-routes.test.ts tests/llm-routes.test.ts tests/mobile-analysis-routes.test.ts tests/apple-verifier.test.ts tests/iap-routes.test.ts tests/payment.test.ts tests/admin-token-refunds.test.ts
npm run typecheck
npm run build
npm test
```

Expected: focused tests, typecheck, and build pass. If the known load-test RSS benchmark fails only in the full suite, rerun that file alone and record both outputs.

- [ ] **Step 3: Commit and deploy disabled**

```bash
git add AGENTS.md .env.example
git commit -m "docs: record token topup rollout"
```

Apply `schema.sql`, deploy with purchases disabled, then smoke-test `/auth/me`, catalog, wallet privacy, existing relay, and a staged credit. Enable only after all client plans pass.
