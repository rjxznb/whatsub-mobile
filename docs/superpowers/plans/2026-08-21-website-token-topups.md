# Website Token Top-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let authenticated Pro users buy ¥10/¥45/¥125 Token packs through Alipay and inspect their shared balance without exposing account data by email alone.

**Architecture:** `/topup` establishes a short-lived session through existing email OTP, then fetches the backend catalog/wallet and creates authenticated orders. The existing success page recognizes Token products and displays the credited balance.

**Tech Stack:** Next.js, React, TypeScript, Tailwind CSS, repository test runner, existing payment API

**Spec:** `whatsub-mobile/docs/superpowers/specs/2026-08-21-llm-entitlements-and-token-topups-design.md`

## Global Constraints

- Only active Pro accounts create Token orders.
- Packs are 1M/¥10, 5M/¥45, and 15M/¥125.
- Wallet and history require bearer auth; typed email alone is insufficient.
- Copy states Tokens never expire but freeze when Pro expires.
- Existing license and subscription checkout behavior remains unchanged.

---

### Task 1: Browser OTP session client

**Files:**
- Modify: `whatsub-website/package.json`
- Create: `whatsub-website/vitest.config.ts`
- Create: `whatsub-website/src/test/setup.ts`
- Create: `whatsub-website/src/lib/account-auth.ts`
- Create: `whatsub-website/src/lib/account-auth.test.ts`

**Interfaces:**
- Produces: `sendAccountCode`, `verifyAccountCode`, `loadAccountSession`, `clearAccountSession`

- [ ] **Step 1: Add the repository's first unit-test runner**

Install `vitest`, `jsdom`, `@testing-library/react`, `@testing-library/jest-dom`, and `@testing-library/user-event` as dev dependencies. Add `"test": "vitest run"` to scripts, configure `environment: 'jsdom'`, and import `@testing-library/jest-dom/vitest` from `src/test/setup.ts`.

- [ ] **Step 2: Write the failing storage test**

```ts
it('stores a normalized verified session only in sessionStorage', async () => {
  mockFetch.mockResolvedValue(new Response(JSON.stringify({ sessionToken: 'tok', expiresAt: 9999 })));
  await verifyAccountCode('Pro@X.com', '424242');
  expect(JSON.parse(sessionStorage.getItem('whatsub.account.session.v1')!)).toMatchObject({ email: 'pro@x.com', token: 'tok' });
  expect(localStorage.getItem('whatsub.account.session.v1')).toBeNull();
});
```

- [ ] **Step 3: Run and prove the module is missing**

Run: `npm test -- account-auth.test.ts`

- [ ] **Step 4: Implement OTP and expiry handling**

Use `/api/license/auth/send-code` and `/api/license/auth/verify-code`. Normalize email to lowercase, discard expired session records, and never log code/token.

- [ ] **Step 5: Run and commit**

```bash
npm test -- account-auth.test.ts
git add package.json package-lock.json vitest.config.ts src/test/setup.ts src/lib/account-auth.ts src/lib/account-auth.test.ts
git commit -m "feat(account): add browser OTP session"
```

### Task 2: Add wallet and top-up API types

**Files:**
- Modify: `whatsub-website/src/lib/payment-api.ts`
- Create: `whatsub-website/src/lib/token-topup-api.test.ts`

**Interfaces:**
- Produces: `getTopupCatalog`, `getTokenWallet`, `createTokenTopupOrder`, `getTokenTransactions`

- [ ] **Step 1: Write the failing authenticated request test**

```ts
it('creates a topup order with bearer auth and no client amount', async () => {
  await createTokenTopupOrder('whatsub_token_5m', 'session-token');
  expect(mockFetch).toHaveBeenCalledWith('/api/license/payment/create-order', expect.objectContaining({
    headers: expect.objectContaining({ Authorization: 'Bearer session-token' }),
    body: JSON.stringify({ product: 'whatsub_token_5m' }),
  }));
});
```

- [ ] **Step 2: Run and prove exports are missing**

Run: `npm test -- token-topup-api.test.ts`

- [ ] **Step 3: Add exact DTOs and calls**

```ts
export type TokenTopupProductId = 'whatsub_token_1m' | 'whatsub_token_5m' | 'whatsub_token_15m';
export interface TokenWallet {
  monthlyUsed: number; monthlyLimit: number; topupBalance: number;
  topupFrozen: boolean; periodResetAt: number;
}
```

- [ ] **Step 4: Run and commit**

```bash
npm test -- token-topup-api.test.ts
git add src/lib/payment-api.ts src/lib/token-topup-api.test.ts
git commit -m "feat(payment): add token topup API client"
```

### Task 3: Build authenticated `/topup` page

**Files:**
- Create: `whatsub-website/src/app/topup/page.tsx`
- Create: `whatsub-website/src/components/TokenTopupCard.tsx`
- Create: `whatsub-website/src/components/TokenTopupCard.test.tsx`

**Interfaces:**
- Consumes: Tasks 1-2

- [ ] **Step 1: Write failing interaction tests**

```tsx
it('shows wallet after OTP and submits the selected server product', async () => {
  render(<TokenTopupCard />);
  await loginWithOtp('pro@x.com', '424242');
  expect(await screen.findByText('充值余额 2.4M')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: /5M.*¥45/ }));
  expect(createTokenTopupOrder).toHaveBeenCalledWith('whatsub_token_5m', 'tok');
});

it('shows subscription recovery instead of checkout for non-Pro', async () => {
  mockCreateOrderError('topup_requires_pro');
  render(<TokenTopupCard />);
  expect(await screen.findByRole('link', { name: '订阅 Pro' })).toHaveAttribute('href', '/#pro');
});
```

- [ ] **Step 2: Run and prove components are missing**

Run: `npm test -- TokenTopupCard.test.tsx`

- [ ] **Step 3: Implement explicit states**

Render OTP login; active-Pro wallet with three packs and the latest 50 recharge transactions; non-Pro explanation. Include “充值 Token 永不过期，但仅在 Pro 有效期间可使用”. Redirect only to backend-returned `payUrl`. Track quota-page exposure, pack selection, checkout result, and balance refresh without email, session token, order number, or transaction ID metadata.

- [ ] **Step 4: Run tests/build and commit**

```bash
npm test -- TokenTopupCard.test.tsx
npm run build
git add src/app/topup/page.tsx src/components/TokenTopupCard.tsx src/components/TokenTopupCard.test.tsx
git commit -m "feat(web): add Pro token topups"
```

### Task 4: Render top-up payment receipts

**Files:**
- Modify: `whatsub-website/src/app/payment/success/page.tsx`
- Modify: `whatsub-website/src/lib/payment-api.ts`
- Create: `whatsub-website/src/app/payment/success/page.test.tsx`

- [ ] **Step 1: Add failing Token receipt test**

```tsx
it('renders credited Tokens instead of a license key', async () => {
  mockStatus({ status: 'paid', product: 'whatsub_token_1m', creditedTokens: 1_000_000, topupBalance: 3_000_000 });
  render(<PaymentSuccessPage />);
  expect(await screen.findByText('1M Token 已到账')).toBeInTheDocument();
  expect(screen.getByText('当前充值余额 3M')).toBeInTheDocument();
});
```

- [ ] **Step 2: Run, implement product branch, rerun**

Run: `npm test -- payment/success/page.test.tsx`

Expected before: FAIL on old product union. Expected after: PASS without changing license/subscription branches.

- [ ] **Step 3: Commit**

```bash
git add src/app/payment/success/page.tsx src/lib/payment-api.ts src/app/payment/success/page.test.tsx
git commit -m "feat(web): show token credit receipts"
```

### Task 5: Verify and stage website

**Files:**
- Modify: `whatsub-website/AGENTS.md`

- [ ] **Step 1: Run full verification**

```bash
npm test
npm run build
```

- [ ] **Step 2: Document and commit**

Document OTP session scope, `/topup`, product IDs, and disabled-first rollout.

```bash
git add AGENTS.md
git commit -m "docs: record website token checkout"
```

- [ ] **Step 3: Deploy hidden and smoke-test**

Verify OTP, owner-only wallet, non-Pro rejection, staged Pro payment, duplicate polling, and receipt. Keep navigation hidden while backend catalog is disabled.
