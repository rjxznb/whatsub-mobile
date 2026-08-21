# Desktop LLM Entitlement Gating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove BYOK from free and subscription-only desktop accounts, retain it for ¥59.9 licenses, and make quota recovery offer only valid actions.

**Architecture:** Rust `auth_me` carries backend capabilities into Zustand. A pure policy filters settings and guards provider creation; quota recovery derives subscribe/top-up/wait/BYOK CTAs from the same object and refreshes wallet state after web checkout.

**Tech Stack:** Tauri, Rust, React, TypeScript, Zustand, Vitest, Testing Library

**Spec:** `whatsub-mobile/docs/superpowers/specs/2026-08-21-llm-entitlements-and-token-topups-design.md`

## Global Constraints

- Free/trial: managed only; license-only: BYOK only; Pro-only: managed only; license + Pro: both.
- Stored provider secrets remain on disk but cannot be read by a disallowed call.
- Desktop opens website `/topup`; wallet truth always comes from backend.
- Paused analyses retain checkpoints and resume without retranscription.

---

### Task 1: Carry capabilities through Rust and Zustand

**Files:**
- Modify: `whatsub/client/src-tauri/src/commands/auth.rs`
- Modify: `whatsub/client/src/store/auth.ts`
- Modify: `whatsub/client/src/store/auth.test.ts`

**Interfaces:**
- Produces: Rust/TS `LlmEntitlements`, `useAuth.llmEntitlements`

- [ ] **Step 1: Add failing decode/reset test**

```ts
it('stores and clears LLM capabilities with the session', async () => {
  invoke.mockResolvedValueOnce({ authenticated: true, email: 'both@x.com',
    hasActiveLicense: true, hasActiveSubscription: true,
    llmEntitlements: { tier: 'buyout_pro', managedRelay: true, byok: true, tokenTopups: true } });
  await useAuth.getState().refresh();
  expect(useAuth.getState().llmEntitlements?.tier).toBe('buyout_pro');
  await useAuth.getState().logout();
  expect(useAuth.getState().llmEntitlements).toBeNull();
});
```

- [ ] **Step 2: Run and prove state is missing**

Run: `npm test -- src/store/auth.test.ts`

- [ ] **Step 3: Add serde and TS types**

```ts
export interface LlmEntitlements {
  tier: 'free' | 'buyout' | 'pro' | 'buyout_pro';
  managedRelay: boolean;
  byok: boolean;
  tokenTopups: boolean;
}
```

Rust uses camelCase serde and `Option` for compatibility with an older backend.

- [ ] **Step 4: Run and commit**

```bash
npm test -- src/store/auth.test.ts
cargo test --manifest-path src-tauri/Cargo.toml auth
git add src-tauri/src/commands/auth.rs src/store/auth.ts src/store/auth.test.ts
git commit -m "feat(auth): sync desktop LLM entitlements"
```

### Task 2: Centralize provider policy and migration

**Files:**
- Create: `whatsub/client/src/llm/entitlementPolicy.ts`
- Create: `whatsub/client/src/llm/entitlementPolicy.test.ts`
- Modify: `whatsub/client/src/store/settings.ts`
- Modify: `whatsub/client/src/llm/providers/index.ts`

**Interfaces:**
- Produces: `allowedLlmModes`, `coerceLlmSettings`, `assertLlmProviderAllowed`

- [ ] **Step 1: Write matrix test**

```ts
it.each([
  ['free', false, true, 'whatsub-managed'],
  ['buyout', true, false, 'deepseek'],
  ['pro', false, true, 'whatsub-managed'],
  ['buyout_pro', true, true, 'deepseek'],
])('%s coerces the active provider safely', (tier, byok, managedRelay, expected) => {
  const result = coerceLlmSettings(settingsWithVendor('deepseek'),
    { tier, byok, managedRelay, tokenTopups: tier === 'pro' || tier === 'buyout_pro' });
  expect(result.vendorId).toBe(expected);
});
```

- [ ] **Step 2: Run and prove module is missing**

Run: `npm test -- src/llm/entitlementPolicy.test.ts`

- [ ] **Step 3: Implement policy without deleting secrets**

`coerceLlmSettings` changes only active vendor/protocol. Retain `openaiCompatible.apiKey`, URL, and model. `assertLlmProviderAllowed` throws `LlmEntitlementError('byok_not_entitled')` before provider creation.

- [ ] **Step 4: Add bypass regression test**

Call `getProvider` with free entitlements and persisted direct vendor; expect `byok_not_entitled` before fetch/Tauri invocation.

- [ ] **Step 5: Run and commit**

```bash
npm test -- src/llm/entitlementPolicy.test.ts src/llm/providers/openaiCompatible.test.ts
git add src/llm/entitlementPolicy.ts src/llm/entitlementPolicy.test.ts src/store/settings.ts src/llm/providers/index.ts src/llm/providers/openaiCompatible.test.ts
git commit -m "feat(llm): gate desktop BYOK by license"
```

### Task 3: Restrict first-run and Settings UI

**Files:**
- Modify: `whatsub/client/src/components/FirstRunGate.tsx`
- Modify: `whatsub/client/src/pages/Settings.tsx`
- Create: `whatsub/client/src/pages/Settings.llm-entitlements.test.tsx`

- [ ] **Step 1: Write UI matrix tests**

```tsx
it('hides BYOK vendors for Pro-only', () => {
  seedEntitlements({ tier: 'pro', managedRelay: true, byok: false, tokenTopups: true });
  render(<Settings />);
  expect(screen.getByText('whatSub 托管 LLM')).toBeInTheDocument();
  expect(screen.queryByText('API Key')).not.toBeInTheDocument();
});
it('shows relay and BYOK for buyout + Pro', () => {
  seedEntitlements({ tier: 'buyout_pro', managedRelay: true, byok: true, tokenTopups: true });
  render(<Settings />);
  expect(screen.getByText('whatSub 托管 LLM')).toBeInTheDocument();
  expect(screen.getByText('API Key')).toBeInTheDocument();
});
```

- [ ] **Step 2: Run and prove unrestricted list fails**

Run: `npm test -- src/pages/Settings.llm-entitlements.test.tsx`

- [ ] **Step 3: Filter both surfaces with the policy**

Free/Pro copy never mentions switching API. Buyout-only explains permanent authorization uses the user's API. Both-tier retains selection.

- [ ] **Step 4: Run and commit**

```bash
npm test -- src/pages/Settings.llm-entitlements.test.tsx src/components/FirstRunGate.keyHelp.test.ts
git add src/components/FirstRunGate.tsx src/pages/Settings.tsx src/pages/Settings.llm-entitlements.test.tsx
git commit -m "feat(settings): present entitled LLM modes"
```

### Task 4: Capability-aware quota recovery

**Files:**
- Modify: `whatsub/client/src/llm/quotaRecovery.ts`
- Modify: `whatsub/client/src/llm/quotaRecovery.test.ts`
- Modify: `whatsub/client/src/components/ProgressBanner.tsx`
- Modify: `whatsub/client/src/components/DownloadQueueWidget.tsx`
- Modify: `whatsub/client/src/components/ImportModal.tsx`
- Modify: corresponding component tests

**Interfaces:**
- Produces: `quotaRecoveryActions(details, entitlements)`

- [ ] **Step 1: Write CTA matrix test**

```ts
it.each([
  ['free', ['subscribe']],
  ['pro', ['topup', 'wait']],
  ['buyout_pro', ['topup', 'byok', 'wait']],
])('%s gets valid recovery actions', (tier, expected) => {
  expect(quotaRecoveryActions(exhausted, entitlements(tier)).map(x => x.kind)).toEqual(expected);
});
```

- [ ] **Step 2: Run and prove hard-coded BYOK fails**

Run: `npm test -- src/llm/quotaRecovery.test.ts`

- [ ] **Step 3: Replace all fixed “切换自己的 API” CTAs**

`topup` opens `https://whatsub.eversay.cc/topup`; `subscribe` opens `/#pro`; `byok` navigates to settings; `wait` shows Beijing reset time.

- [ ] **Step 4: Run and commit**

```bash
npm test -- src/llm/quotaRecovery.test.ts src/components/ProgressBanner.test.tsx src/components/DownloadQueueWidget.test.tsx src/components/ImportModal.test.tsx
git add src/llm/quotaRecovery.ts src/llm/quotaRecovery.test.ts src/components/ProgressBanner.tsx src/components/ProgressBanner.test.tsx src/components/DownloadQueueWidget.tsx src/components/DownloadQueueWidget.test.tsx src/components/ImportModal.tsx src/components/ImportModal.test.tsx
git commit -m "feat(llm): tailor desktop quota recovery"
```

### Task 5: Refresh wallet and resume after checkout

**Files:**
- Create: `whatsub/client/src/lib/api/tokenWallet.ts`
- Create: `whatsub/client/src/lib/api/tokenWallet.test.ts`
- Modify: `whatsub/client/src/store/backgroundAnalyses.ts`
- Modify: `whatsub/client/src/components/ManagedRelayQuotaPanel.tsx`

- [ ] **Step 1: Add failing resume test**

```ts
it('resumes only quota-paused jobs when capacity increases', async () => {
  seedPausedJob({ committedCueOffset: 150 });
  await refreshAfterTopup({ before: 0, after: 1_000_000 });
  expect(resumeBackgroundAnalysis).toHaveBeenCalledWith(expect.objectContaining({ committedCueOffset: 150 }));
});
```

- [ ] **Step 2: Implement owner wallet refresh on window focus**

After opening checkout, refresh auth plus wallet on focus, show the latest recharge transactions in `ManagedRelayQuotaPanel`, and resume only quota-paused jobs when subscription or wallet capacity increases. Never restart cancelled or format/upstream failures. Track quota-wall exposure, top-up click, capacity refresh, and resume result without subtitle, prompt, Key, or transaction-ID payloads.

- [ ] **Step 3: Run and commit**

```bash
npm test -- src/lib/api/tokenWallet.test.ts src/store/backgroundAnalyses.test.ts
git add src/lib/api/tokenWallet.ts src/lib/api/tokenWallet.test.ts src/store/backgroundAnalyses.ts src/components/ManagedRelayQuotaPanel.tsx
git commit -m "feat(llm): resume desktop jobs after topup"
```

### Task 6: Verify and release desktop

**Files:**
- Modify: `whatsub/client/CLAUDE.md`

- [ ] **Step 1: Run complete verification**

```bash
cd client
npm test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml
```

- [ ] **Step 2: Verify four fixture accounts**

Confirm free/Pro saved keys remain stored but unselectable; buyout uses BYOK; buyout + Pro switches both ways; quota-paused cursor survives top-up.

- [ ] **Step 3: Document, commit, and release after backend/website**

```bash
git add CLAUDE.md
git commit -m "docs: record desktop LLM entitlement policy"
```
