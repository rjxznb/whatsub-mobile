# iOS Live Activity for Desktop Import Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single aggregate Live Activity that tracks the user's desktop import queue progress via APNs push, showing live state on lock-screen + Dynamic Island (where available).

**Architecture:** Backend pushes `(inProgress, completed, failed, recentTitle)` to Apple's APNs HTTP/2 endpoint on every `import_queue` state change. iOS WidgetKit re-renders the Activity's ContentState without the main app foregrounded. Activity lifecycle owned by a singleton `LiveActivityCoordinator` in the main app.

**Tech Stack:** Hono + Postgres backend, Node `crypto` for APNs JWT, ActivityKit + WidgetKit on iOS 16.1+, XcodeGen for the new extension target, vitest for backend TDD.

**Spec reference:** `docs/superpowers/specs/2026-06-18-ios-live-activity-import-queue-design.md`

---

## Phase 0 — Manual prerequisites

These are blocking but **only need to be done once**. Do these in parallel with Phase 1 if possible; they don't block code but do block end-to-end smoke testing.

### Task 0.1: Create APNs Auth Key in Apple Developer Portal

**Files:** None (manual)

- [ ] **Step 1: Create the Auth Key**

Open https://developer.apple.com/account/resources/authkeys/list → Keys → ➕ →
- Name: `whatSub APNs Production`
- Services: ✅ **Apple Push Notifications service (APNs)**
- Click Continue, then Register
- **Download the .p8 file** (one chance only — Apple won't let you re-download)
- Note the 10-char **Key ID**

- [ ] **Step 2: Add to GitHub Actions Secrets (for CI later)**

Repo Settings → Secrets and variables → Actions → New repository secret:
- `APNS_KEY_ID`: the 10-char Key ID
- `APNS_KEY_P8`: full content of `AuthKey_<KEY_ID>.p8` including PEM headers
- `APNS_TEAM_ID`: `Q3BK52FQT9` (already known)

- [ ] **Step 3: Delete local `.p8` file**

Same hygiene as the App Store Connect API key (per `CLAUDE.md`). The .p8 lives only in GitHub Secrets after this point.

### Task 0.2: Enable Push Notifications capability on the main app

**Files:** `whatsub-mobile/whatsub-mobile.entitlements`, `project.yml`

- [ ] **Step 1: Verify entitlements path**

Run: `Get-Content C:/Users/renjx/Desktop/whatsub-mobile/whatsub-mobile/whatsub-mobile.entitlements`
Expected: existing entitlements XML (or "file not found" — create it then).

- [ ] **Step 2: Add aps-environment key**

Edit `whatsub-mobile/whatsub-mobile.entitlements`, inside the existing `<dict>`:
```xml
<key>aps-environment</key>
<string>development</string>
```

(Becomes `production` when the App Store distribution build is signed — Xcode handles this swap via the entitlement file selected by `CODE_SIGN_ENTITLEMENTS` per configuration. We're starting with `development` so TestFlight builds reach APNs sandbox.)

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/whatsub-mobile.entitlements
git commit -m "feat(ios): add aps-environment entitlement for Live Activity push"
```

### Task 0.3: Set Aliyun backend env vars

**Files:** Server-side `/opt/whatsub/.env` + `docker-compose.yml`

- [ ] **Step 1: Add env vars to compose file**

Run:
```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 "cat /opt/whatsub/docker-compose.yml | grep -A2 'whatsub-license:' | grep -A20 environment"
```

Add to the `environment:` block under the `whatsub-license` service (NOT just `.env` — per `CLAUDE.md`'s "Deploy gotcha: OSS/CDN env must be in compose block" memory):

```yaml
      - APNS_KEY_ID=${APNS_KEY_ID}
      - APNS_TEAM_ID=${APNS_TEAM_ID}
      - APNS_KEY_P8=${APNS_KEY_P8}
      - APNS_TOPIC=cc.eversay.whatsub.mobile.push-type.liveactivity
      - APNS_ENVIRONMENT=development
```

- [ ] **Step 2: Add the values to `.env`**

```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206
nano /opt/whatsub/.env
# Append:
APNS_KEY_ID=<from Task 0.1>
APNS_TEAM_ID=Q3BK52FQT9
APNS_KEY_P8=<paste full PEM>
```

- [ ] **Step 3: Verify (don't recreate yet — backend code isn't deployed)**

```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 'cat /opt/whatsub/.env | grep APNS_KEY_ID'
```
Expected: prints the key id (or no output if not set — fix and retry).

---

## Phase 1 — Backend foundation (TDD)

### Task 1.1: Schema migration for `live_activity_tokens`

**Files:**
- Modify: `whatsub-license/schema.sql`

- [ ] **Step 1: Append the new table**

Edit `whatsub-license/schema.sql`, append to the bottom:

```sql
-- Live Activity push tokens (iOS, 2026-06-18). One row per active Activity per
-- device. Backend fan-outs APNs pushes across all rows for a given email.
CREATE TABLE IF NOT EXISTS live_activity_tokens (
  email          TEXT NOT NULL,
  push_token     TEXT NOT NULL,
  activity_id    TEXT NOT NULL,
  registered_at  BIGINT NOT NULL,
  expires_at     BIGINT NOT NULL,
  PRIMARY KEY (email, activity_id)
);
CREATE INDEX IF NOT EXISTS live_activity_tokens_email_idx
  ON live_activity_tokens (email);
```

- [ ] **Step 2: Apply to prod Postgres**

```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 'docker exec -i enghub-postgres-1 psql -U whatsub -d whatsub' < whatsub-license/schema.sql
```

Expected: `CREATE TABLE` (or `NOTICE: relation already exists, skipping`) + `CREATE INDEX`.

- [ ] **Step 3: Verify**

```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 'docker exec enghub-postgres-1 psql -U whatsub -d whatsub -c "\d live_activity_tokens"'
```
Expected: shows 5 columns + primary key.

- [ ] **Step 4: Commit**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
git add schema.sql
git commit -m "feat(library): live_activity_tokens table for iOS Live Activity push fan-out"
```

### Task 1.2: Db methods for activity tokens (TDD)

**Files:**
- Modify: `whatsub-license/src/lib/db.ts`
- Test: `whatsub-license/tests/live-activity-tokens.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/live-activity-tokens.test.ts`:

```typescript
import { describe, test, expect, beforeEach } from 'vitest';
import { Pool } from 'pg';
import { Db } from '../src/lib/db';

const pool = new Pool({ connectionString: process.env.DATABASE_URL ?? 'postgres://test@localhost/test' });
const db = new Db(pool);

describe('live_activity_tokens', () => {
  beforeEach(async () => {
    await pool.query("DELETE FROM live_activity_tokens WHERE email = 'la-test@x.com'");
  });

  test('upsert + list', async () => {
    await db.upsertLiveActivityToken({
      email: 'la-test@x.com',
      activityId: 'act-1',
      pushToken: 'tok-a',
      now: Date.now(),
      expiresAt: Date.now() + 8 * 3600_000,
    });
    const list = await db.listLiveActivityTokensForEmail('la-test@x.com');
    expect(list).toHaveLength(1);
    expect(list[0]?.pushToken).toBe('tok-a');
  });

  test('upsert replaces same (email, activityId) row', async () => {
    const t = Date.now();
    await db.upsertLiveActivityToken({ email: 'la-test@x.com', activityId: 'act-1', pushToken: 'tok-a', now: t, expiresAt: t + 1000 });
    await db.upsertLiveActivityToken({ email: 'la-test@x.com', activityId: 'act-1', pushToken: 'tok-b', now: t, expiresAt: t + 1000 });
    const list = await db.listLiveActivityTokensForEmail('la-test@x.com');
    expect(list).toHaveLength(1);
    expect(list[0]?.pushToken).toBe('tok-b');
  });

  test('delete', async () => {
    const t = Date.now();
    await db.upsertLiveActivityToken({ email: 'la-test@x.com', activityId: 'act-1', pushToken: 'tok-a', now: t, expiresAt: t + 1000 });
    await db.deleteLiveActivityToken('la-test@x.com', 'act-1');
    expect(await db.listLiveActivityTokensForEmail('la-test@x.com')).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run test → expect FAIL**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
pnpm test live-activity-tokens
```
Expected: 3 FAILs (`upsertLiveActivityToken is not a function`).

- [ ] **Step 3: Implement Db methods**

In `src/lib/db.ts`, ADD ABOVE the existing `async deleteLibraryEntry` (line ~2180):

```typescript
async upsertLiveActivityToken(input: {
  email: string;
  activityId: string;
  pushToken: string;
  now: number;
  expiresAt: number;
}): Promise<void> {
  await this.pool.query(
    `INSERT INTO live_activity_tokens (email, push_token, activity_id, registered_at, expires_at)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (email, activity_id) DO UPDATE SET
       push_token    = EXCLUDED.push_token,
       registered_at = EXCLUDED.registered_at,
       expires_at    = EXCLUDED.expires_at`,
    [input.email, input.pushToken, input.activityId, input.now, input.expiresAt],
  );
}

async listLiveActivityTokensForEmail(email: string): Promise<{
  pushToken: string;
  activityId: string;
  expiresAt: number;
}[]> {
  const res = await this.pool.query<{ push_token: string; activity_id: string; expires_at: string }>(
    `SELECT push_token, activity_id, expires_at FROM live_activity_tokens WHERE email = $1`,
    [email],
  );
  return res.rows.map((r) => ({
    pushToken: r.push_token,
    activityId: r.activity_id,
    expiresAt: Number(r.expires_at),
  }));
}

async deleteLiveActivityToken(email: string, activityId: string): Promise<void> {
  await this.pool.query(
    `DELETE FROM live_activity_tokens WHERE email = $1 AND activity_id = $2`,
    [email, activityId],
  );
}
```

- [ ] **Step 4: Run tests → expect PASS**

```bash
pnpm test live-activity-tokens
```
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/db.ts tests/live-activity-tokens.test.ts
git commit -m "feat(library): Db methods for live_activity_tokens (upsert/list/delete) + tests"
```

### Task 1.3: Title lookup helper for import_queue (TDD)

**Files:**
- Modify: `whatsub-license/src/lib/db.ts`
- Test: `whatsub-license/tests/live-activity-tokens.test.ts` (extend)

- [ ] **Step 1: Write failing test**

Append to `tests/live-activity-tokens.test.ts`:

```typescript
import { randomUUID } from 'crypto';

describe('getImportQueueTitle', () => {
  test('returns title for known id', async () => {
    const id = randomUUID();
    await pool.query(
      `INSERT INTO import_queue (id, email, url, title, status, created_at)
       VALUES ($1, 'iq-test@x.com', 'https://example.com', 'Pour-Over Coffee', 'pending', $2)`,
      [id, Date.now()],
    );
    expect(await db.getImportQueueTitle(id)).toBe('Pour-Over Coffee');
  });

  test('returns null for unknown id', async () => {
    expect(await db.getImportQueueTitle('nonexistent-' + randomUUID())).toBeNull();
  });
});
```

- [ ] **Step 2: Run test → expect FAIL**

```bash
pnpm test live-activity-tokens
```
Expected: `getImportQueueTitle is not a function`.

- [ ] **Step 3: Implement**

In `src/lib/db.ts`, add (next to the other library/import methods):

```typescript
async getImportQueueTitle(id: string): Promise<string | null> {
  const res = await this.pool.query<{ title: string | null }>(
    `SELECT title FROM import_queue WHERE id = $1`,
    [id],
  );
  return res.rows[0]?.title ?? null;
}
```

- [ ] **Step 4: Run tests → expect PASS + Commit**

```bash
pnpm test live-activity-tokens
git add src/lib/db.ts tests/live-activity-tokens.test.ts
git commit -m "feat(library): getImportQueueTitle helper for Live Activity recentTitle"
```

### Task 1.4: APNs JWT signer + HTTP/2 push module (TDD)

**Files:**
- Create: `whatsub-license/src/lib/apnsPush.ts`
- Test: `whatsub-license/tests/apns-push.test.ts`

- [ ] **Step 1: Write failing test (signing only — HTTP/2 is mocked)**

Create `tests/apns-push.test.ts`:

```typescript
import { describe, test, expect, vi } from 'vitest';
import { signApnsJwt, ApnsContentStateUpdate } from '../src/lib/apnsPush';

const TEST_KEY = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----`;

describe('signApnsJwt', () => {
  test('produces a JWT with the expected header + claims', () => {
    const jwt = signApnsJwt({
      keyId: 'ABC1234567',
      teamId: 'Q3BK52FQT9',
      privateKeyPem: TEST_KEY,
      now: 1734567890,
    });
    const [headerB64, payloadB64] = jwt.split('.');
    const header = JSON.parse(Buffer.from(headerB64!, 'base64url').toString());
    const payload = JSON.parse(Buffer.from(payloadB64!, 'base64url').toString());
    expect(header.alg).toBe('ES256');
    expect(header.kid).toBe('ABC1234567');
    expect(payload.iss).toBe('Q3BK52FQT9');
    expect(payload.iat).toBe(1734567890);
    expect(jwt.split('.').length).toBe(3);
  });
});

describe('pushUpdate', () => {
  test('POSTs to api.development.push.apple.com when env=development', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 200 }));
    const { pushUpdate } = await import('../src/lib/apnsPush');
    const ok = await pushUpdate({
      pushToken: 'deadbeef',
      contentState: { inProgress: 1, completed: 0, failed: 0, recentTitle: 'X' },
      env: 'development',
      keyId: 'ABC1234567',
      teamId: 'Q3BK52FQT9',
      privateKeyPem: TEST_KEY,
      topic: 'cc.eversay.whatsub.mobile.push-type.liveactivity',
      now: 1734567890,
      fetch: fetchMock,
    });
    expect(ok).toBe(true);
    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(url).toMatch(/^https:\/\/api\.development\.push\.apple\.com\/3\/device\/deadbeef$/);
    const headers = (init as RequestInit).headers as Record<string, string>;
    expect(headers['apns-topic']).toBe('cc.eversay.whatsub.mobile.push-type.liveactivity');
    expect(headers['apns-push-type']).toBe('liveactivity');
    expect(headers['authorization']).toMatch(/^bearer /);
    const body = JSON.parse((init as RequestInit).body as string);
    expect(body.aps.event).toBe('update');
    expect(body.aps['content-state'].inProgress).toBe(1);
  });

  test('returns false on non-2xx response', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 410 }));
    const { pushUpdate } = await import('../src/lib/apnsPush');
    const ok = await pushUpdate({
      pushToken: 'deadbeef',
      contentState: { inProgress: 0, completed: 1, failed: 0, recentTitle: null },
      env: 'production',
      keyId: 'ABC1234567',
      teamId: 'Q3BK52FQT9',
      privateKeyPem: TEST_KEY,
      topic: 'cc.eversay.whatsub.mobile.push-type.liveactivity',
      now: 1734567890,
      fetch: fetchMock,
    });
    expect(ok).toBe(false);
  });
});
```

- [ ] **Step 2: Run test → expect FAIL**

```bash
pnpm test apns-push
```
Expected: `Cannot find module '../src/lib/apnsPush'`.

- [ ] **Step 3: Implement `apnsPush.ts`**

Create `src/lib/apnsPush.ts`:

```typescript
import { createSign } from 'crypto';

export type ApnsContentStateUpdate = {
  inProgress: number;
  completed: number;
  failed: number;
  recentTitle: string | null;
};

export type ApnsEnv = 'development' | 'production';

const HOST: Record<ApnsEnv, string> = {
  development: 'https://api.development.push.apple.com',
  production: 'https://api.push.apple.com',
};

/**
 * Sign an APNs JWT using ES256 (the only algorithm Apple accepts for token-
 * based authentication). Per Apple's docs the token is valid for 1 hour but
 * must be refreshed at least every 20 minutes — callers should cache the
 * `(token, iat)` pair and re-sign when iat is older than 20min.
 */
export function signApnsJwt(opts: {
  keyId: string;
  teamId: string;
  privateKeyPem: string;
  now: number;   // epoch seconds
}): string {
  const header = { alg: 'ES256', kid: opts.keyId };
  const payload = { iss: opts.teamId, iat: opts.now };
  const enc = (o: object) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const headerB64 = enc(header);
  const payloadB64 = enc(payload);
  const signer = createSign('SHA256');
  signer.update(`${headerB64}.${payloadB64}`);
  // dsaEncoding: 'ieee-p1363' produces the 64-byte raw r||s signature Apple expects.
  // Default 'der' produces ASN.1 which Apple rejects with InvalidProviderToken.
  const sig = signer.sign({ key: opts.privateKeyPem, dsaEncoding: 'ieee-p1363' });
  return `${headerB64}.${payloadB64}.${sig.toString('base64url')}`;
}

export async function pushUpdate(opts: {
  pushToken: string;
  contentState: ApnsContentStateUpdate;
  env: ApnsEnv;
  keyId: string;
  teamId: string;
  privateKeyPem: string;
  topic: string;
  now: number;
  fetch?: typeof globalThis.fetch;
}): Promise<boolean> {
  const fetchFn = opts.fetch ?? globalThis.fetch;
  const jwt = signApnsJwt({
    keyId: opts.keyId,
    teamId: opts.teamId,
    privateKeyPem: opts.privateKeyPem,
    now: opts.now,
  });
  const url = `${HOST[opts.env]}/3/device/${opts.pushToken}`;
  const body = {
    aps: {
      timestamp: opts.now,
      event: 'update' as const,
      'content-state': opts.contentState,
      'stale-date': opts.now + 3600,  // 1h freshness window
    },
  };
  const res = await fetchFn(url, {
    method: 'POST',
    headers: {
      authorization: `bearer ${jwt}`,
      'apns-topic': opts.topic,
      'apns-push-type': 'liveactivity',
      'apns-priority': '10',
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  return res.status >= 200 && res.status < 300;
}

export async function pushEnd(opts: {
  pushToken: string;
  finalState: ApnsContentStateUpdate;
  env: ApnsEnv;
  keyId: string;
  teamId: string;
  privateKeyPem: string;
  topic: string;
  now: number;
  fetch?: typeof globalThis.fetch;
}): Promise<boolean> {
  const fetchFn = opts.fetch ?? globalThis.fetch;
  const jwt = signApnsJwt({
    keyId: opts.keyId,
    teamId: opts.teamId,
    privateKeyPem: opts.privateKeyPem,
    now: opts.now,
  });
  const url = `${HOST[opts.env]}/3/device/${opts.pushToken}`;
  const body = {
    aps: {
      timestamp: opts.now,
      event: 'end' as const,
      'content-state': opts.finalState,
      'dismissal-date': opts.now + 600,  // dismiss 10min after end
    },
  };
  const res = await fetchFn(url, {
    method: 'POST',
    headers: {
      authorization: `bearer ${jwt}`,
      'apns-topic': opts.topic,
      'apns-push-type': 'liveactivity',
      'apns-priority': '10',
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  return res.status >= 200 && res.status < 300;
}
```

- [ ] **Step 4: Run tests → expect PASS**

```bash
pnpm test apns-push
```
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/apnsPush.ts tests/apns-push.test.ts
git commit -m "feat(library): APNs JWT signer + HTTP/2 pushUpdate/pushEnd for Live Activity"
```

### Task 1.5: `pushQueueStateForEmail` helper

**Files:**
- Modify: `whatsub-license/src/lib/db.ts` (new helper method)

- [ ] **Step 1: Write the helper as a class method**

In `src/lib/db.ts`, ABOVE the existing `async deleteLibraryEntry`:

```typescript
/** Aggregate queue counts for one email — keyed by status (pending/processing
 * count as "in progress", completed and failed are terminal). */
async getImportQueueAggregateForEmail(email: string): Promise<{
  inProgress: number;
  completed: number;
  failed: number;
}> {
  const res = await this.pool.query<{ status: string; n: string }>(
    `SELECT status, COUNT(*)::text as n FROM import_queue
      WHERE email = $1 GROUP BY status`,
    [email],
  );
  let inProgress = 0, completed = 0, failed = 0;
  for (const r of res.rows) {
    const n = Number(r.n);
    if (r.status === 'pending' || r.status === 'processing' || r.status === 'claimed') inProgress += n;
    else if (r.status === 'completed') completed += n;
    else if (r.status === 'failed') failed += n;
  }
  return { inProgress, completed, failed };
}
```

(The `claimed` status comes from `whatsub-license` `/import-queue/:id/claim` route — desktop client claims a row before processing.)

- [ ] **Step 2: Write a non-Db helper in `apnsPush.ts`**

In `src/lib/apnsPush.ts`, at the bottom:

```typescript
/**
 * Push a queue state update to ALL Live Activity tokens for one email.
 * Best-effort: APNs failures are logged + dropped; next state change will
 * re-send the full snapshot. We don't fail the calling DB transaction.
 *
 * Inputs read from process.env (caller doesn't have to repeat them):
 *   APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8, APNS_TOPIC, APNS_ENVIRONMENT
 *
 * If any are missing we silently no-op — useful for local dev where APNs
 * isn't set up.
 */
export async function pushQueueStateForEmail(
  db: {
    getImportQueueAggregateForEmail(email: string): Promise<{
      inProgress: number;
      completed: number;
      failed: number;
    }>;
    listLiveActivityTokensForEmail(email: string): Promise<{
      pushToken: string;
      activityId: string;
      expiresAt: number;
    }[]>;
  },
  email: string,
  recentTitle: string | null,
): Promise<void> {
  const keyId = process.env.APNS_KEY_ID;
  const teamId = process.env.APNS_TEAM_ID;
  const privateKeyPem = process.env.APNS_KEY_P8;
  const topic = process.env.APNS_TOPIC;
  const env = (process.env.APNS_ENVIRONMENT ?? 'development') as ApnsEnv;
  if (!keyId || !teamId || !privateKeyPem || !topic) {
    console.log('[apnsPush] missing env, skipping push');
    return;
  }
  const [counts, tokens] = await Promise.all([
    db.getImportQueueAggregateForEmail(email),
    db.listLiveActivityTokensForEmail(email),
  ]);
  if (tokens.length === 0) return;
  const contentState = { ...counts, recentTitle };
  const now = Math.floor(Date.now() / 1000);
  await Promise.all(tokens.map(async (t) => {
    try {
      const ok = await pushUpdate({
        pushToken: t.pushToken,
        contentState,
        env,
        keyId,
        teamId,
        privateKeyPem,
        topic,
        now,
      });
      if (!ok) console.warn(`[apnsPush] non-2xx for ${t.activityId.slice(0, 8)}`);
    } catch (e) {
      console.error('[apnsPush] error', t.activityId.slice(0, 8), e);
    }
  }));
}
```

- [ ] **Step 3: Smoke test compile**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
pnpm build
```
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add src/lib/db.ts src/lib/apnsPush.ts
git commit -m "feat(library): pushQueueStateForEmail helper (best-effort APNs fan-out)"
```

---

## Phase 2 — Backend endpoints + DB hooks

### Task 2.1: `POST /api/live-activity/register` endpoint (TDD)

**Files:**
- Create: `whatsub-license/src/routes/liveActivity.ts`
- Modify: `whatsub-license/src/index.ts` (mount the route)
- Test: `whatsub-license/tests/live-activity-routes.test.ts`

- [ ] **Step 1: Write failing test**

Create `tests/live-activity-routes.test.ts`:

```typescript
import { describe, test, expect, beforeEach } from 'vitest';
import { app, db, signAuthTokenForEmail } from './setup';  // existing test harness

beforeEach(async () => {
  await db.pool.query("DELETE FROM live_activity_tokens WHERE email = 'la-route@x.com'");
});

describe('POST /api/live-activity/register', () => {
  test('401 without bearer', async () => {
    const res = await app.request('/api/live-activity/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ activityId: 'a', pushToken: 'b' }),
    });
    expect(res.status).toBe(401);
  });

  test('200 + row inserted', async () => {
    const token = await signAuthTokenForEmail('la-route@x.com');
    const res = await app.request('/api/live-activity/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ activityId: 'act-x', pushToken: 'tok-x' }),
    });
    expect(res.status).toBe(200);
    const list = await db.listLiveActivityTokensForEmail('la-route@x.com');
    expect(list).toHaveLength(1);
    expect(list[0]?.pushToken).toBe('tok-x');
  });

  test('400 missing fields', async () => {
    const token = await signAuthTokenForEmail('la-route@x.com');
    const res = await app.request('/api/live-activity/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(400);
  });
});
```

(If the test harness exports differ, mirror what's done in `tests/iap-routes.test.ts`.)

- [ ] **Step 2: Run test → expect FAIL**

```bash
pnpm test live-activity-routes
```
Expected: 404 Not Found (route not mounted yet).

- [ ] **Step 3: Implement the route**

Create `src/routes/liveActivity.ts`:

```typescript
import { Hono } from 'hono';
import type { Db } from '../lib/db';
import { requireSession } from '../middleware/requireSession';

export function liveActivityRoutes(db: Db) {
  const app = new Hono();

  app.post('/register', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    let body: Record<string, unknown>;
    try {
      body = (await c.req.json()) as Record<string, unknown>;
    } catch {
      return c.json({ error: 'invalid_json' }, 400);
    }
    const activityId = typeof body.activityId === 'string' ? body.activityId.trim() : '';
    const pushToken = typeof body.pushToken === 'string' ? body.pushToken.trim() : '';
    if (!activityId || !pushToken) return c.json({ error: 'invalid_input' }, 400);
    const now = Date.now();
    await db.upsertLiveActivityToken({
      email,
      activityId,
      pushToken,
      now,
      expiresAt: now + 8 * 3600_000,
    });
    return c.json({ ok: true });
  });

  app.post('/end', requireSession(db), async (c) => {
    const email = c.get('email' as never) as string;
    let body: Record<string, unknown>;
    try {
      body = (await c.req.json()) as Record<string, unknown>;
    } catch {
      return c.json({ error: 'invalid_json' }, 400);
    }
    const activityId = typeof body.activityId === 'string' ? body.activityId.trim() : '';
    if (!activityId) return c.json({ error: 'invalid_input' }, 400);
    await db.deleteLiveActivityToken(email, activityId);
    return c.json({ ok: true });
  });

  return app;
}
```

- [ ] **Step 4: Mount the route**

Edit `src/index.ts`. Find where existing routes mount (e.g., `app.route('/api/library', libraryRoutes(db))`). Add:

```typescript
import { liveActivityRoutes } from './routes/liveActivity';
// ...
app.route('/api/live-activity', liveActivityRoutes(db));
```

- [ ] **Step 5: Run tests → expect PASS**

```bash
pnpm test live-activity-routes
```
Expected: 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add src/routes/liveActivity.ts src/index.ts tests/live-activity-routes.test.ts
git commit -m "feat(library): POST /api/live-activity/{register,end} endpoints"
```

### Task 2.2: Hook `pushQueueStateForEmail` into queue mutations

**Files:**
- Modify: `whatsub-license/src/routes/library.ts` (existing `import-queue` POST routes)

- [ ] **Step 1: Find the enqueue handler**

```bash
grep -n "import-queue\|enqueue\|setImportQueueStatus" C:/Users/renjx/Desktop/whatsub-license/src/routes/library.ts | head
```

You'll see 3 places:
- `app.post('/import-queue', ...)` — user enqueue
- `app.post('/import-queue/:id/status', ...)` — desktop status update
- `app.post('/import-queue/:id/claim', ...)` — desktop claim

- [ ] **Step 2: Add `pushQueueStateForEmail` call after each successful mutation**

After each `await db.<mutation>(…)` that changes import_queue rows, add:

```typescript
// Best-effort Live Activity push — never blocks the response.
import('./lib/apnsPush').then(async (m) => {
  const title = body.title || (await db.getImportQueueTitle(id)) || null;
  await m.pushQueueStateForEmail(db, email, title);
}).catch((e) => console.error('[apnsPush] hook error', e));
```

Inline the import to avoid loading the apns module when not needed. Pass `email` from `c.get('email')` (already in scope) and the title from the request body where available, else from the row lookup.

(Three call sites — apply the same wrapper to each.)

- [ ] **Step 3: Smoke test build**

```bash
pnpm build
```
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add src/routes/library.ts
git commit -m "feat(library): fire APNs push on every import_queue mutation (best-effort)"
```

### Task 2.3: Deploy backend to prod

**Files:** None (deploy artifact)

- [ ] **Step 1: Build + buildx image**

```bash
cd C:/Users/renjx/Desktop/whatsub-license
pnpm build
docker buildx build --platform linux/amd64 -t whatsub-license:latest -o type=docker .
```

- [ ] **Step 2: Save + scp**

```bash
docker save whatsub-license:latest | gzip > /tmp/whatsub-license.tar.gz
scp -i ~/.ssh/id_ed25519 /tmp/whatsub-license.tar.gz root@47.93.87.206:/tmp/
```

- [ ] **Step 3: Load + recreate container on Aliyun**

```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 'cd /opt/whatsub && docker load < /tmp/whatsub-license.tar.gz && docker compose up -d --force-recreate whatsub-license'
```

- [ ] **Step 4: Probe the new endpoint**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" -d '{}' https://whatsub.eversay.cc/api/live-activity/register
```
Expected: `401` (auth required = endpoint exists). If `404` → check route mount.

- [ ] **Step 5: Cleanup + commit**

```bash
ssh -i ~/.ssh/id_ed25519 root@47.93.87.206 'rm /tmp/whatsub-license.tar.gz'
rm /tmp/whatsub-license.tar.gz
cd C:/Users/renjx/Desktop/whatsub-license
git push origin main
```

---

## Phase 3 — iOS Widget Extension scaffolding

### Task 3.1: Create the Widget Extension directory + Info.plist

**Files:**
- Create: `whatsub-mobile/whatsub-widget/Info.plist`
- Create: `whatsub-mobile/whatsub-widget/WhatsubWidgetBundle.swift`

- [ ] **Step 1: Create the directory + Info.plist**

```powershell
mkdir C:/Users/renjx/Desktop/whatsub-mobile/whatsub-widget
```

Create `whatsub-mobile/whatsub-widget/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
```

- [ ] **Step 2: Create the Widget Bundle entry**

Create `whatsub-mobile/whatsub-widget/WhatsubWidgetBundle.swift`:

```swift
import SwiftUI
import WidgetKit

@main
struct WhatsubWidgetBundle: WidgetBundle {
    var body: some Widget {
        ImportActivityWidget()
    }
}
```

(Empty `ImportActivityWidget` will be defined in Task 4.x; build will fail until then — that's OK for this commit.)

- [ ] **Step 3: Commit (build will fail by design — placeholder only)**

```bash
cd C:/Users/renjx/Desktop/whatsub-mobile
git add whatsub-widget/
git commit -m "chore(widget): scaffold whatsub-widget extension directory + bundle entry"
```

### Task 3.2: Register the Widget target in `project.yml`

**Files:**
- Modify: `whatsub-mobile/project.yml`

- [ ] **Step 1: Find the existing `whatsub-share` target block (template for ours)**

```bash
grep -n "whatsub-share:\|app-extension" project.yml
```

- [ ] **Step 2: Add a new target block**

Append to `targets:` in `project.yml`:

```yaml
  whatsub-widget:
    type: app-extension
    platform: iOS
    deploymentTarget: "16.1"
    sources:
      - whatsub-widget
      - whatsub-mobile/Shared/ImportActivityAttributes.swift
      - whatsub-mobile/App/Theme.swift
    info:
      path: whatsub-widget/Info.plist
      properties:
        CFBundleDisplayName: whatSub Widget
        CFBundleIdentifier: cc.eversay.whatsub.mobile.widget
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: cc.eversay.whatsub.mobile.widget
        SWIFT_VERSION: "5.10"
        TARGETED_DEVICE_FAMILY: "1,2"
        CODE_SIGN_STYLE: Automatic
        INFOPLIST_KEY_NSExtension__NSExtensionPointIdentifier: com.apple.widgetkit-extension
    dependencies:
      - sdk: WidgetKit.framework
      - sdk: ActivityKit.framework
      - sdk: SwiftUI.framework
```

Then under the **main `whatsub-mobile` target**, add this dependency so the extension embeds:

```yaml
    dependencies:
      - target: whatsub-widget
```

(Find the existing main-target `dependencies:` or `sources:` block; insert near other target-deps if present.)

- [ ] **Step 3: Regenerate the project (verify locally if you have a Mac)**

```bash
# On Mac:
xcodegen generate
# On Windows: only verify YAML is valid:
python -c "import yaml; yaml.safe_load(open('project.yml'))" || echo "yaml error"
```

- [ ] **Step 4: Commit**

```bash
git add project.yml
git commit -m "chore(widget): register whatsub-widget extension target in project.yml"
```

### Task 3.3: Shared `ImportActivityAttributes` struct

**Files:**
- Create: `whatsub-mobile/whatsub-mobile/Shared/ImportActivityAttributes.swift`

- [ ] **Step 1: Verify the Shared/ directory exists**

```bash
ls C:/Users/renjx/Desktop/whatsub-mobile/whatsub-mobile/Shared/
```
Expected: `AppGroup.swift` (or similar).

- [ ] **Step 2: Create the attributes file**

Create `whatsub-mobile/whatsub-mobile/Shared/ImportActivityAttributes.swift`:

```swift
import Foundation
import ActivityKit

/// Shared between the main app (`whatsub-mobile`) and the Widget Extension
/// (`whatsub-widget`). Both targets compile this file via project.yml's
/// per-target `sources:` list — same pattern as AppGroup.swift.
///
/// The ContentState is what backend pushes to APNs and what the Widget UI
/// reads. The outer ActivityAttributes (userEmail) is fixed for the lifetime
/// of an Activity instance and not mutated by pushes.
struct ImportActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public let inProgress: Int
        public let completed: Int
        public let failed: Int
        public let recentTitle: String?

        public init(inProgress: Int, completed: Int, failed: Int, recentTitle: String?) {
            self.inProgress = inProgress
            self.completed = completed
            self.failed = failed
            self.recentTitle = recentTitle
        }
    }

    public let userEmail: String

    public init(userEmail: String) {
        self.userEmail = userEmail
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Shared/ImportActivityAttributes.swift
git commit -m "feat(widget): shared ImportActivityAttributes (Codable for APNs payload)"
```

---

## Phase 4 — Widget UI

### Task 4.1: Lock-screen card SwiftUI view

**Files:**
- Create: `whatsub-mobile/whatsub-widget/LockScreenCard.swift`

- [ ] **Step 1: Implement the lock-screen layout**

Create `whatsub-mobile/whatsub-widget/LockScreenCard.swift`:

```swift
import SwiftUI

struct LockScreenCard: View {
    let state: ImportActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconForState)
                    .foregroundStyle(.whatsubAccent)
                Text(titleForState)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                Spacer()
            }
            Divider().background(Color.white.opacity(0.1))
            HStack(spacing: 12) {
                statBlock(label: "进行中", count: state.inProgress, color: .whatsubAccent)
                statBlock(label: "完成",   count: state.completed,  color: .green)
                statBlock(label: "失败",   count: state.failed,     color: .red.opacity(0.85))
            }
            if let title = state.recentTitle, !title.isEmpty {
                Text("最近：\(title)")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
                    .lineLimit(1)
            }
        }
        .padding(14)
    }

    private var iconForState: String {
        if state.inProgress > 0 { return "tray.and.arrow.down.fill" }
        if state.failed > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var titleForState: String {
        if state.inProgress > 0 { return "视频导入处理中" }
        if state.failed > 0 { return "部分导入失败" }
        return "全部完成"
    }

    private func statBlock(label: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.whatsubInkMuted)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add whatsub-widget/LockScreenCard.swift
git commit -m "feat(widget): lock screen Activity card layout"
```

### Task 4.2: Dynamic Island compact + minimal + expanded views

**Files:**
- Create: `whatsub-mobile/whatsub-widget/ImportActivityWidget.swift`

- [ ] **Step 1: Implement the full `ImportActivityWidget`**

Create `whatsub-mobile/whatsub-widget/ImportActivityWidget.swift`:

```swift
import SwiftUI
import WidgetKit
import ActivityKit

struct ImportActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ImportActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(Color.whatsubBgElev)
                .activitySystemActionForegroundColor(Color.whatsubInk)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .foregroundStyle(.whatsubAccent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.completed)/\(totalCount(context.state))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.whatsubInk)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        ProgressView(value: progressFraction(context.state))
                            .tint(.whatsubAccent)
                        if let title = context.state.recentTitle, !title.isEmpty {
                            Text(title)
                                .font(.caption2)
                                .foregroundStyle(.whatsubInkMuted)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(bottomHint(context.state))
                        .font(.caption2)
                        .foregroundStyle(.whatsubInkMuted)
                }
            } compactLeading: {
                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundStyle(.whatsubAccent)
            } compactTrailing: {
                Text("\(context.state.inProgress)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.whatsubInk)
            } minimal: {
                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundStyle(.whatsubAccent)
            }
            .widgetURL(URL(string: tapDestination(context.state)))
        }
    }

    private func totalCount(_ s: ImportActivityAttributes.ContentState) -> Int {
        s.inProgress + s.completed + s.failed
    }

    private func progressFraction(_ s: ImportActivityAttributes.ContentState) -> Double {
        let total = totalCount(s)
        return total == 0 ? 0 : Double(s.completed + s.failed) / Double(total)
    }

    private func bottomHint(_ s: ImportActivityAttributes.ContentState) -> String {
        if s.inProgress > 0 { return "点击查看队列详情 →" }
        if s.failed > 0 { return "有 \(s.failed) 个失败 — 点击查看 →" }
        return "点击打开 Library →"
    }

    private func tapDestination(_ s: ImportActivityAttributes.ContentState) -> String {
        s.inProgress > 0 ? "whatsub://import-queue" : "whatsub://library"
    }
}
```

- [ ] **Step 2: Smoke build (CI is the verification — push)**

```bash
git add whatsub-widget/ImportActivityWidget.swift
git commit -m "feat(widget): Dynamic Island compact/minimal/expanded + lock-screen wiring"
git push origin main
```

Watch CI: `gh run watch <run-id> --repo rjxznb/whatsub-mobile --exit-status`
Expected: CI sim build PASS. TestFlight will deploy a build that LOADS the widget bundle — visual verification waits until Phase 7.

### Task 4.3: Verify visual layouts via simctl push (simulator only)

**Files:** None (manual)

- [ ] **Step 1: Run the app on simulator + enqueue a fake Activity**

Add a debug-only "Trigger fake Activity" button in MeView temporarily, or modify `LiveActivityCoordinator` (after Task 5.1) to expose a `debugStart()` method.

- [ ] **Step 2: Push a state update via simctl**

```bash
# Get device id:
xcrun simctl list devices booted
# Push payload:
echo '{"aps":{"timestamp":1734567890,"event":"update","content-state":{"inProgress":2,"completed":5,"failed":1,"recentTitle":"How to Pour-Over Coffee"}}}' > /tmp/payload.json
xcrun simctl push <DEVICE_ID> cc.eversay.whatsub.mobile /tmp/payload.json
```

- [ ] **Step 3: Visual check**

Lock the simulator (⌘L) — Activity card should appear with the counts.
Expected: 进行中 2 · 完成 5 · 失败 1 · 最近：How to Pour-Over Coffee.

(Phase 7 has the real device test for Dynamic Island.)

---

## Phase 5 — Main app `LiveActivityCoordinator`

### Task 5.1: Coordinator singleton skeleton

**Files:**
- Create: `whatsub-mobile/whatsub-mobile/App/LiveActivityCoordinator.swift`

- [ ] **Step 1: Implement the skeleton**

Create `whatsub-mobile/whatsub-mobile/App/LiveActivityCoordinator.swift`:

```swift
import Foundation
import ActivityKit
import UIKit

/// Owns the single Live Activity for the import queue. Lifecycle:
///   1. App imports a URL to desktop → `ensureActivity` starts one if absent.
///   2. ActivityKit hands us a push token → we POST it to backend so APNs
///      pushes can reach this Activity.
///   3. Backend pushes ContentState updates to APNs; iOS WidgetKit re-renders
///      the Activity automatically. The main app sees nothing.
///   4. On foreground after all done + 10min, `endIfStale` ends the Activity.
@MainActor
final class LiveActivityCoordinator: ObservableObject {
    static let shared = LiveActivityCoordinator()
    private init() {}

    private var currentActivity: Activity<ImportActivityAttributes>?
    private var pushTokenTask: Task<Void, Never>?
    /// Epoch seconds when the last item terminated (completed or failed) AND
    /// inProgress became 0. Used by endIfStale to enforce the 10-min cooldown.
    private var allDoneAt: Double?

    /// Start an Activity if none exists. Idempotent — repeat calls are no-ops
    /// while one is already running.
    func ensureActivity(forUserEmail email: String, initialState: ImportActivityAttributes.ContentState) async {
        if let existing = currentActivity, existing.activityState == .active {
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return  // User disabled Live Activities globally.
        }
        let attributes = ImportActivityAttributes(userEmail: email)
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: nil),
                pushType: .token
            )
            currentActivity = activity
            // Spawn a task that listens for the push token (Apple delivers it
            // asynchronously after .request returns). On each token, POST it
            // to backend so APNs has a destination.
            pushTokenTask = Task { [weak self] in
                for await tokenData in activity.pushTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    await self?.uploadToken(hex, activityId: activity.id, email: email)
                }
            }
        } catch {
            // Common: user denied permission, target device lacks Activity
            // support (iPad pre-iOS 16.1), entitlement missing. Silent fall-
            // through — the in-app 我的 → 导入队列 view still works.
            print("[LA] activity request failed: \(error)")
        }
    }

    /// Called on app foreground (scenePhase = .active) to honor the 10-min
    /// auto-end policy from the spec §2.4.
    func endIfStale() async {
        guard let activity = currentActivity else { return }
        let s = activity.content.state
        if s.inProgress == 0 {
            let now = Date().timeIntervalSince1970
            if let start = allDoneAt {
                if now - start > 600 {
                    await activity.end(activity.content, dismissalPolicy: .default)
                    await uploadEnd(activityId: activity.id)
                    currentActivity = nil
                    allDoneAt = nil
                }
            } else {
                allDoneAt = now
            }
        } else {
            allDoneAt = nil  // came back in-progress, reset cooldown
        }
    }

    private func uploadToken(_ hex: String, activityId: String, email: String) async {
        // Implemented in Task 5.2 once WhatsubAPI has the method.
    }

    private func uploadEnd(activityId: String) async {
        // Implemented in Task 5.2.
    }
}
```

- [ ] **Step 2: Smoke build + commit**

```bash
git add whatsub-mobile/App/LiveActivityCoordinator.swift
git commit -m "feat(ios): LiveActivityCoordinator singleton skeleton"
```

### Task 5.2: WhatsubAPI methods for token register / end

**Files:**
- Modify: `whatsub-mobile/whatsub-mobile/Networking/WhatsubAPI.swift`
- Modify: `whatsub-mobile/whatsub-mobile/App/LiveActivityCoordinator.swift`

- [ ] **Step 1: Add WhatsubAPI methods**

In `WhatsubAPI.swift`, after the existing library methods, add:

```swift
// ----- Live Activity -----

func registerLiveActivityToken(activityId: String, pushToken: String, token: String) async throws {
    let body = ["activityId": activityId, "pushToken": pushToken]
    let data = try JSONSerialization.data(withJSONObject: body)
    _ = try await postExpectingOk(Endpoints.api("live-activity/register"), body: data, bearer: token)
}

func endLiveActivity(activityId: String, token: String) async throws {
    let body = ["activityId": activityId]
    let data = try JSONSerialization.data(withJSONObject: body)
    _ = try await postExpectingOk(Endpoints.api("live-activity/end"), body: data, bearer: token)
}
```

(If `Endpoints.api(...)` builder doesn't exist, mirror the existing `Endpoints.library(...)` pattern.)

- [ ] **Step 2: Wire the coordinator to use them**

In `LiveActivityCoordinator.swift`, replace the empty `uploadToken` + `uploadEnd` with:

```swift
private func uploadToken(_ hex: String, activityId: String, email: String) async {
    // Read the session token from AppState. AppState is an @EnvironmentObject
    // but we need a non-env access here — read from UserDefaults where the
    // session is mirrored (existing pattern used by other coordinators).
    guard let bearer = SessionStore.currentToken() else { return }
    do {
        try await WhatsubAPI.shared.registerLiveActivityToken(
            activityId: activityId,
            pushToken: hex,
            token: bearer,
        )
    } catch {
        print("[LA] register failed: \(error)")
    }
}

private func uploadEnd(activityId: String) async {
    guard let bearer = SessionStore.currentToken() else { return }
    try? await WhatsubAPI.shared.endLiveActivity(activityId: activityId, token: bearer)
}
```

(If `SessionStore.currentToken()` doesn't exist, mirror what `BackgroundAudioCoordinator` does to access AppState — see `whatsub-mobile/Components/BackgroundAudioCoordinator.swift`.)

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Networking/WhatsubAPI.swift whatsub-mobile/App/LiveActivityCoordinator.swift
git commit -m "feat(ios): WhatsubAPI.registerLiveActivityToken/endLiveActivity + wire coordinator"
```

### Task 5.3: Hook into `ImportViewModel.pushToDesktop`

**Files:**
- Modify: `whatsub-mobile/whatsub-mobile/Import/ImportViewModel.swift`

- [ ] **Step 1: Add the trigger after successful enqueue**

In `ImportViewModel.swift`, find `pushToDesktop` (it currently POSTs to `/import-queue`). After the success branch, add:

```swift
// Start (or refresh) the Live Activity so the user has lock-screen / Dynamic
// Island visibility into desktop processing. Best-effort: failure means no
// Activity, in-app queue view still works.
if let email = AppStateAccessor.currentEmail() {
    let initial = ImportActivityAttributes.ContentState(
        inProgress: 1,    // we just enqueued
        completed: 0,
        failed: 0,
        recentTitle: title,
    )
    await LiveActivityCoordinator.shared.ensureActivity(
        forUserEmail: email,
        initialState: initial,
    )
}
```

(`AppStateAccessor.currentEmail()` mirrors the SessionStore.currentToken() helper from Task 5.2 — if not present, add it.)

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Import/ImportViewModel.swift
git commit -m "feat(ios): start Live Activity on pushToDesktop success"
```

### Task 5.4: scenePhase + URL-open routing in `WhatsubMobileApp`

**Files:**
- Modify: `whatsub-mobile/whatsub-mobile/App/WhatsubMobileApp.swift`

- [ ] **Step 1: Trigger `endIfStale` on foreground**

Find the existing `.onChange(of: scenePhase) { phase in ... }` block. Add inside the `.active` branch:

```swift
Task { await LiveActivityCoordinator.shared.endIfStale() }
```

- [ ] **Step 2: Handle the new deep-link URLs**

Find the existing `.onOpenURL { url in ... }` block. Extend the switch:

```swift
.onOpenURL { url in
    switch url.host {
    case "import":
        // existing share-extension path
        ...
    case "import-queue":
        // Switch to MeView tab + push ImportQueueView.
        // Implementation depends on existing AppState routing — find the
        // pattern used by other deep links and mirror.
        appState.pendingDestination = .importQueue
    case "library":
        appState.selectedTab = .library
    default:
        break
    }
}
```

(If `AppState` doesn't have `pendingDestination` / `.importQueue`, add them — single Bool/enum, ~5 lines of model code.)

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/App/WhatsubMobileApp.swift whatsub-mobile/App/AppState.swift
git commit -m "feat(ios): scenePhase endIfStale + deep-link routing for Live Activity tap"
```

---

## Phase 6 — End-to-end smoke + polish

### Task 6.1: Wire `MeView` → 导入队列 deep-link destination

**Files:**
- Modify: `whatsub-mobile/whatsub-mobile/Me/MeView.swift` (if not already navigation-stack-based)

- [ ] **Step 1: Verify ImportQueueView reachable via pendingDestination**

Existing `ImportQueueView` is already mounted under MeView's NavigationLink. Make sure tapping the Live Activity ends with the user seeing it. If MeView uses a NavigationStack, set its `path` from `appState.pendingDestination` on appear.

- [ ] **Step 2: Manual test on simulator**

Push the simctl payload (Task 4.3 Step 2). Tap the lock-screen card. App opens; should land on import-queue view (since state has inProgress > 0).

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(ios): route Live Activity tap → 导入队列 / Library based on state"
```

### Task 6.2: Push the build to TestFlight

**Files:** None (CI handles)

- [ ] **Step 1: Push main**

```bash
git push origin main
```

- [ ] **Step 2: Watch CI**

```bash
gh run list --repo rjxznb/whatsub-mobile --limit 2
gh run watch <id> --exit-status
```

- [ ] **Step 3: Verify TestFlight delivers new build**

Apple Connect → TestFlight → check build number incremented (CI auto-bumps).

---

## Phase 7 — Device testing

### Task 7.1: Physical device — iPhone 14 Pro+ for Dynamic Island

**Files:** None (manual)

- [ ] **Step 1: Install TestFlight build on iPhone 14 Pro+**

- [ ] **Step 2: Confirm permission flow**

First app launch → push permission prompt (because Live Activity needs APNs reachability). Tap Allow.

- [ ] **Step 3: Enqueue an import**

我的 → 导入视频 → paste any URL → 推送到桌面端处理.

- [ ] **Step 4: Observe Dynamic Island**

Within 2-3 seconds:
- Compact: tray icon left, count "1" right.
- Lock the screen — card appears.
- Long-press Dynamic Island — expanded view with progress bar + title.

- [ ] **Step 5: Wait for desktop processing (or fake it via DB write)**

When desktop completes the item, APNs push fires. Verify state updates in real time.

- [ ] **Step 6: Verify tap routing**

While inProgress > 0 — tap → opens 导入队列 view.
After all done — tap → opens Library tab.

### Task 7.2: Physical device — iPhone 13 (lock-screen card only)

- [ ] **Step 1: Install same TestFlight build on iPhone 13**

- [ ] **Step 2: Verify lock-screen card**

Same enqueue flow. Lock screen → card present. No Dynamic Island (expected). Notification Center → card present.

### Task 7.3: 10-minute auto-end verification

- [ ] **Step 1: After all items reach terminal state, leave the app backgrounded for 11 minutes**

- [ ] **Step 2: Foreground**

Activity should disappear from lock-screen card on next foreground (endIfStale fires).

### Task 7.4: ASC review notes preamble

**Files:**
- Modify: ASC App Information → Review Notes (manual, ASC web UI)

- [ ] **Step 1: Add a paragraph to Review Notes**

```
This build adds a Live Activity that shows desktop import-queue progress
on the lock screen + Dynamic Island. To test:
  1. Sign in with appreview@eversay.cc / 424242.
  2. 我的 → 导入视频 → paste any URL → 推送到桌面端处理.
  3. Lock screen — Activity card with counts appears within 2-3 seconds.

The Activity uses APNs push for state updates. No user notification permission
is required (Live Activity push is a separate iOS-permission-free path).
The aps-environment entitlement is set to "development" for TestFlight and
"production" for App Store distribution — auto-switched by Xcode signing.
```

---

## Phase 8 — Cleanup + memory

### Task 8.1: Update CLAUDE.md "Post-v1 features shipped"

**Files:**
- Modify: `whatsub-mobile/CLAUDE.md`

- [ ] **Step 1: Append to the "Post-v1 features shipped" section**

Add a short paragraph (~60 words) describing the Live Activity feature, mirroring the format of existing entries (e.g., "Self-hosted video", "Share-to-import").

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude.md): document Live Activity feature in shipped features"
```

### Task 8.2: Memory updates

**Files:**
- Create: `C:/Users/renjx/.claude/projects/C--Users-renjx-Desktop-whatsub-mobile/memory/project_live_activity.md`
- Modify: `C:/Users/renjx/.claude/projects/C--Users-renjx-Desktop-whatsub-mobile/memory/MEMORY.md`

- [ ] **Step 1: Write the memory**

Topic + Why + How to apply. ~80 words.

- [ ] **Step 2: Add an index entry to MEMORY.md**

One line, < 150 chars.

- [ ] **Step 3: Commit**

(memory dir is outside the repo — no git commit needed.)

---

## Self-review checklist (already executed)

**Spec coverage:**
- §3.1.1 schema → Task 1.1 ✓
- §3.1.2 register endpoint → Task 2.1 ✓
- §3.1.3 end endpoint → Task 2.1 ✓
- §3.1.4 apnsPush.ts → Task 1.4 ✓
- §3.1.5 hooks into mutations → Task 2.2 ✓
- §3.1.6 title backfill → Task 1.3 ✓
- §3.1.7 env vars → Task 0.3 ✓
- §3.2.1 widget target → Task 3.2 ✓
- §3.2.2 shared attributes → Task 3.3 ✓
- §3.2.3 widget config → Task 4.2 ✓
- §3.2.4 visual layouts → Task 4.1 + 4.2 ✓
- §3.3.1 Coordinator → Task 5.1 + 5.2 ✓
- §3.3.2 ImportViewModel hook → Task 5.3 ✓
- §3.3.3 deep-link routing → Task 5.4 ✓
- §3.3.4 foreground hygiene → Task 5.4 ✓
- §4 error handling — distributed across Coordinator skeleton + apnsPush best-effort ✓
- §5 testing strategy → Phase 7 ✓

**Placeholder scan:** None.

**Type consistency:** ContentState fields (inProgress, completed, failed, recentTitle?) consistent across backend payload + Swift struct + Widget UI references.

**Total estimate matches spec §8:** Backend ~1.5 days (Phases 1-2), iOS ~1.5-2 days (Phases 3-6), device testing 0.5-1 day (Phase 7), polish 0.25 day (Phase 8). **~4-5 days total.**
