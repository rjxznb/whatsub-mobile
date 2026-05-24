# iOS Monetization — Phase 2A (Real Apple Verifier) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Phase-1 `null` verifier with a real Apple JWS verifier so `POST /api/iap/verify` and the ASSN V2 webhook actually validate StoreKit transactions, then deploy the backend to prod.

**Architecture:** A new `src/lib/appleVerifier.ts` implements the existing `IapVerifier` interface (from `src/routes/iap.ts`) using Apple's official `@apple/app-store-server-library` `SignedDataVerifier`. The *pure* decode→domain mapping (product→kind, decoded payload→`VerifiedTransaction`/`VerifiedNotification`) is split into testable functions; the cryptographic verification (the library call) is a thin wrapper exercised in sandbox. The verifier is built from env config in `index.ts` and injected into `iapRoute(db, verifier)`; if config is absent it stays `null` (endpoints 503), preserving Phase-1 behavior.

**Tech Stack:** TypeScript, Hono, `@apple/app-store-server-library`, Vitest. Repo: `whatsub-license`. Branch: `feat/iap-verifier` off `main`.

**Critical deployment facts (already verified):**
- **No nginx change needed.** `nginx/whatsub.conf` has `location /api/license/ { proxy_pass http://whatsub-license:3002/api/; }`, so `/api/license/iap/verify` → backend `/api/iap/verify` and `/api/license/iap/notifications` → backend `/api/iap/notifications` automatically.
- **iOS base URL** (for Phase 2B): `https://whatsub.eversay.cc/api/license/iap`.
- **ASSN V2 webhook URL** (register in App Store Connect): `https://whatsub.eversay.cc/api/license/iap/notifications`.
- Env config pattern: `requireEnv(name)` block inside `index.ts`'s `if (isMain)`. Multi-line PEM/cert values are mounted as **files** (env var holds the in-container path, read with `readFileSync`) — same as the existing Alipay keys.

**Scope guard:** Phase 2A does NOT touch iOS, does NOT change quota/corpus gating, does NOT change the `iapRoute` handler logic (Phase 1 already built `/verify` + `/notifications`; we only supply a real verifier). The `IapVerifier`, `VerifiedTransaction`, `VerifiedNotification` interfaces already exist in `src/routes/iap.ts` — import them, don't redefine.

---

## Product IDs (from App Store Connect)
- Buyout (non-consumable): `cc.eversay.whatsub.mobile.fullunlock`
- Subscription (auto-renewable): `whatsub_pro_month`, `whatsub_pro_year`

---

## Task A1: Pure decode→domain mapping (TDD)

**Files:**
- Create: `src/lib/appleVerifier.ts` (the pure functions only this task)
- Test: `tests/apple-verifier.test.ts`

The pure functions don't touch the Apple library, so they're fully unit-testable.

- [ ] **Step 1: Write the failing test** — create `tests/apple-verifier.test.ts`

```ts
import { describe, it, expect } from 'vitest';
import {
  productKindFor, mapTransaction, mapNotification,
  type DecodedAppleTransaction,
} from '../src/lib/appleVerifier.js';

const buyoutTx: DecodedAppleTransaction = {
  productId: 'cc.eversay.whatsub.mobile.fullunlock',
  originalTransactionId: 'OTX-1',
};
const subTx: DecodedAppleTransaction = {
  productId: 'whatsub_pro_month',
  originalTransactionId: 'OTX-2',
  expiresDate: 1_700_000_000_000,
};

describe('productKindFor', () => {
  it('classifies the buyout product as buyout', () => {
    expect(productKindFor('cc.eversay.whatsub.mobile.fullunlock')).toBe('buyout');
  });
  it('classifies the subscription products as subscription', () => {
    expect(productKindFor('whatsub_pro_month')).toBe('subscription');
    expect(productKindFor('whatsub_pro_year')).toBe('subscription');
  });
  it('defaults unknown products to subscription (safer: never silently grants the permanent buyout)', () => {
    expect(productKindFor('something_else')).toBe('subscription');
  });
});

describe('mapTransaction', () => {
  it('maps a buyout transaction', () => {
    expect(mapTransaction(buyoutTx)).toEqual({
      productId: 'cc.eversay.whatsub.mobile.fullunlock',
      originalTransactionId: 'OTX-1',
      kind: 'buyout',
      expiresDate: undefined,
    });
  });
  it('maps a subscription transaction with its expiry', () => {
    expect(mapTransaction(subTx)).toEqual({
      productId: 'whatsub_pro_month',
      originalTransactionId: 'OTX-2',
      kind: 'subscription',
      expiresDate: 1_700_000_000_000,
    });
  });
});

describe('mapNotification', () => {
  it('builds a VerifiedNotification from a notificationType + decoded transaction', () => {
    expect(mapNotification('DID_RENEW', subTx)).toEqual({
      notificationType: 'DID_RENEW',
      productId: 'whatsub_pro_month',
      originalTransactionId: 'OTX-2',
      kind: 'subscription',
      expiresDate: 1_700_000_000_000,
    });
  });
  it('carries REFUND of the buyout', () => {
    expect(mapNotification('REFUND', buyoutTx)).toEqual({
      notificationType: 'REFUND',
      productId: 'cc.eversay.whatsub.mobile.fullunlock',
      originalTransactionId: 'OTX-1',
      kind: 'buyout',
      expiresDate: undefined,
    });
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (`Cannot find module '../src/lib/appleVerifier.js'`): `pnpm test apple-verifier`

- [ ] **Step 3: Implement the pure functions** — create `src/lib/appleVerifier.ts` with ONLY this for now:

```ts
import type { VerifiedTransaction, VerifiedNotification } from '../routes/iap.js';

/** The subset of Apple's decoded JWS transaction payload we consume. */
export interface DecodedAppleTransaction {
  productId: string;
  originalTransactionId: string;
  expiresDate?: number;   // unix ms; present for subscriptions
}

const BUYOUT_PRODUCT_ID = 'cc.eversay.whatsub.mobile.fullunlock';

/** Our product taxonomy. Only the known buyout id is a buyout; everything else
 *  (the two subscription ids, or anything unexpected) is treated as a subscription
 *  — deliberately conservative so an unknown product never grants the PERMANENT buyout. */
export function productKindFor(productId: string): 'buyout' | 'subscription' {
  return productId === BUYOUT_PRODUCT_ID ? 'buyout' : 'subscription';
}

export function mapTransaction(d: DecodedAppleTransaction): VerifiedTransaction {
  return {
    productId: d.productId,
    originalTransactionId: d.originalTransactionId,
    kind: productKindFor(d.productId),
    expiresDate: d.expiresDate,
  };
}

export function mapNotification(
  notificationType: string,
  d: DecodedAppleTransaction,
): VerifiedNotification {
  return {
    notificationType,
    productId: d.productId,
    originalTransactionId: d.originalTransactionId,
    kind: productKindFor(d.productId),
    expiresDate: d.expiresDate,
  };
}
```

- [ ] **Step 4: Run — expect PASS** (8 tests): `pnpm test apple-verifier` ; then `pnpm typecheck`

- [ ] **Step 5: Commit**

```bash
git add src/lib/appleVerifier.ts tests/apple-verifier.test.ts
git commit -m "feat(iap): pure Apple payload→domain mapping (productKind/mapTransaction/mapNotification)"
```

---

## Task A2: Real verifier via @apple/app-store-server-library

**Files:**
- Modify: `package.json` (add dependency), `src/lib/appleVerifier.ts` (add `createAppleVerifier`)
- Add (setup): `src/lib/apple-root-certs/` (4 Apple Root CA `.cer` files — public PKI, see Step 1)

> **Why no unit test here:** `SignedDataVerifier` performs real cryptographic JWS verification against Apple's certificate chain — it can only succeed on genuinely Apple-signed payloads, which exist only in sandbox/prod (Phase 2B + the integration step). The *logic* around it (field mapping, product classification) is already unit-tested in A1. This task is integration-verified in the deploy step.

- [ ] **Step 1: Add the dependency + Apple root certs**

```bash
pnpm add @apple/app-store-server-library
```
Download the 4 Apple Root CA certificates (public, from https://www.apple.com/certificateauthority/) into `src/lib/apple-root-certs/`:
`AppleComputerRootCertificate.cer`, `AppleRootCA-G2.cer`, `AppleRootCA-G3.cer`, `AppleIncRootCertificate.cer`.
(These get bundled/copied into the image; they are public certificates, safe to commit. Confirm the library's required set against its README for the installed version.)

- [ ] **Step 2: Implement `createAppleVerifier`** — append to `src/lib/appleVerifier.ts`

```ts
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import {
  SignedDataVerifier, Environment,
} from '@apple/app-store-server-library';
import type { IapVerifier } from '../routes/iap.js';

export interface AppleVerifierConfig {
  bundleId: string;          // cc.eversay.whatsub.mobile
  appAppleId: number;        // numeric App Store app id (App Store Connect → App Information)
  environment: 'Sandbox' | 'Production';
  rootCertsDir: string;      // dir containing the Apple Root CA .cer files
}

/**
 * Build the real Apple verifier. Returns an IapVerifier whose verifyTransaction /
 * verifyNotification crypto-verify the JWS via Apple's library, then map the
 * decoded payload to our domain types (A1 functions).
 *
 * NOTE: the exact method/field names below mirror @apple/app-store-server-library;
 * confirm against the installed version's types (e.g. JWSTransactionDecodedPayload,
 * ResponseBodyV2DecodedPayload, data.signedTransactionInfo). Adjust field access
 * if the version differs — the A1 mappers stay the same.
 */
export function createAppleVerifier(cfg: AppleVerifierConfig): IapVerifier {
  const rootCerts = readdirSync(cfg.rootCertsDir)
    .filter((f) => f.endsWith('.cer'))
    .map((f) => readFileSync(join(cfg.rootCertsDir, f)));

  const env = cfg.environment === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX;
  const enableOnlineChecks = true;
  const verifier = new SignedDataVerifier(
    rootCerts, enableOnlineChecks, env, cfg.bundleId, cfg.appAppleId,
  );

  return {
    async verifyTransaction(signedTransactionInfo: string): Promise<VerifiedTransaction> {
      const decoded = await verifier.verifyAndDecodeTransaction(signedTransactionInfo);
      return mapTransaction({
        productId: decoded.productId!,
        originalTransactionId: decoded.originalTransactionId!,
        expiresDate: decoded.expiresDate,
      });
    },
    async verifyNotification(signedPayload: string): Promise<VerifiedNotification> {
      const payload = await verifier.verifyAndDecodeNotification(signedPayload);
      const signedTx = payload.data?.signedTransactionInfo;
      if (!signedTx) throw new Error('notification has no signedTransactionInfo');
      const tx = await verifier.verifyAndDecodeTransaction(signedTx);
      return mapNotification(payload.notificationType ?? 'UNKNOWN', {
        productId: tx.productId!,
        originalTransactionId: tx.originalTransactionId!,
        expiresDate: tx.expiresDate,
      });
    },
  };
}
```
(`VerifiedTransaction`/`VerifiedNotification` are already imported at the top of the file from `../routes/iap.js` via the A1 code — if not, add them to that import.)

- [ ] **Step 3: Verify it compiles** — `pnpm typecheck` (must be clean) and `pnpm test` (the A1 unit tests still pass; no new unit test here).

- [ ] **Step 4: Commit**

```bash
git add package.json pnpm-lock.yaml src/lib/appleVerifier.ts src/lib/apple-root-certs/
git commit -m "feat(iap): real Apple SignedDataVerifier (createAppleVerifier)"
```

---

## Task A3: Wire the verifier from env config

**Files:**
- Modify: `src/index.ts` (build the verifier in the `isMain` block, pass to `iapRoute`)

Phase 1 mounts `app.route('/api/iap', iapRoute(db, null))` *inside `buildApp`*. To inject a real verifier without forcing it on tests, thread an optional verifier through `buildApp` and default to `null`.

- [ ] **Step 1: Thread an optional verifier into `buildApp`**

Find the `buildApp(...)` signature and the `app.route('/api/iap', iapRoute(db, null));` line. Add an optional `iapVerifier` parameter (default `null`) and pass it through:

```ts
// in buildApp's signature, add a trailing optional param:
//   ..., iapVerifier: IapVerifier | null = null
// and change the mount line to:
app.route('/api/iap', iapRoute(db, iapVerifier));
```
Add the import at the top of `index.ts`: `import type { IapVerifier } from './routes/iap.js';`
(Existing callers / tests that call `buildApp` without the new arg keep working — it defaults to `null`.)

- [ ] **Step 2: Build the verifier from env in the `isMain` block**

In `src/index.ts`, inside `if (isMain) { ... }`, after the existing `requireEnv(...)` setup and before `const app = buildApp(...)`, add (env vars are OPTIONAL so the server still boots without IAP configured — logs + falls back to null):

```ts
  // IAP verifier — optional. Without these env vars the /api/iap endpoints stay
  // 503 (same as Phase 1). Set them in prod to enable buyout/subscription verification.
  let iapVerifier: IapVerifier | null = null;
  const appleAppId = process.env.APPLE_APP_APPLE_ID;
  const appleEnv = process.env.APPLE_ENVIRONMENT;        // 'Sandbox' | 'Production'
  const appleCertsDir = process.env.APPLE_ROOT_CERTS_DIR;
  if (appleAppId && appleEnv && appleCertsDir) {
    iapVerifier = createAppleVerifier({
      bundleId: process.env.APPLE_BUNDLE_ID ?? 'cc.eversay.whatsub.mobile',
      appAppleId: parseInt(appleAppId, 10),
      environment: appleEnv === 'Production' ? 'Production' : 'Sandbox',
      rootCertsDir: appleCertsDir,
    });
    console.log(`[iap] Apple verifier enabled (env=${appleEnv})`);
  } else {
    console.log('[iap] Apple verifier NOT configured — /api/iap endpoints will 503');
  }
```
Add the import at the top: `import { createAppleVerifier } from './lib/appleVerifier.js';`
Then pass `iapVerifier` as the new trailing arg to `buildApp(...)`.

- [ ] **Step 3: Typecheck + full test**

`pnpm typecheck` (clean) and `pnpm test` (all green — the default-null keeps existing `iap-routes` tests passing; they construct `iapRoute` directly with a fake verifier and don't go through `buildApp`).

- [ ] **Step 4: Commit**

```bash
git add src/index.ts
git commit -m "feat(iap): build Apple verifier from env + inject into iapRoute (null when unconfigured)"
```

---

## Integration A (REQUIRES USER AUTHORIZATION — touches prod + Apple)

This deploys Phase 1 (already on `main`) **+** Phase 2A together. Do NOT run without the user's go-ahead.

- [ ] Merge `feat/iap-verifier` → `main` (after the per-task reviews pass).
- [ ] **Server env** (`/opt/enghub` docker-compose for `whatsub-license`): add
  - `APPLE_APP_APPLE_ID` = the app's numeric Apple ID (App Store Connect → App → App Information → "Apple ID")
  - `APPLE_ENVIRONMENT` = `Sandbox` (switch to `Production` at public launch)
  - `APPLE_ROOT_CERTS_DIR` = in-container path to the bundled `apple-root-certs/` (image copies them, or mount)
  - `APPLE_BUNDLE_ID` = `cc.eversay.whatsub.mobile` (optional; defaults to this)
- [ ] Build the backend image + ship + restart the container (the project's build-locally→push-image→restart flow). The Phase-1 schema migration must already be applied — apply `schema.sql` now if not (idempotent):
  ```bash
  docker compose -f /opt/enghub/docker-compose.yml exec -T postgres \
    psql -U whatsub_license_user -d whatsub_license < schema.sql
  ```
- [ ] **Register the ASSN V2 webhook** in App Store Connect → your app → App Information → "App Store Server Notifications": set the **Sandbox** (and later Production) URL to `https://whatsub.eversay.cc/api/license/iap/notifications`, Version 2.
- [ ] **Smoke checks:**
  - `GET https://whatsub.eversay.cc/api/license/auth/me` (with a session bearer) returns the Phase-1 fields (`iosBuyout`, `iosSubActive`, `trialExpiresAt`).
  - `POST https://whatsub.eversay.cc/api/license/iap/verify` (bearer, dummy body) now returns `400 invalid_input`/`verification_failed` (NOT `503`) — confirming the verifier is wired (503 would mean env not picked up).
  - In App Store Connect, send a **test notification** → backend logs receipt + 200 (verifies the webhook URL + signature path end-to-end).
- [ ] Full sandbox purchase verification happens in Phase 2B (needs the iOS app to generate a real signed transaction).

## Hand-off to Phase 2B (iOS)
Once 2A is deployed + smoke-checked, the iOS plan can target the confirmed contract:
- Verify endpoint: `POST https://whatsub.eversay.cc/api/license/iap/verify` body `{ signedTransactionInfo }` → returns `{ ok, hasActiveLicense, iosBuyout, iosSubActive, subProductId, trialExpiresAt }`.
- `/me` returns the same entitlement fields.
- ASSN handles renew/expire/refund server-side.
