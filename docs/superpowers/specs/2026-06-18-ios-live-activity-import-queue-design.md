# iOS Live Activity for Desktop Import Queue Status

**Date**: 2026-06-18
**Owner**: rjxznb
**Target devices**: iPhone 14 Pro+ (Dynamic Island), iPhone 8+ (lock-screen card only)
**iOS minimum for this feature**: 16.1+ (`ActivityKit`)
**App iOS minimum stays**: 16.0 — users on 16.0 simply don't see the Activity surface

---

## 1. Context

The app already pushes non-YouTube URLs (Bilibili, generic web pages) to a backend import queue that the user's **desktop client polls + processes** (yt-dlp + Whisper + LLM analysis). Wall-clock duration of one push: **5-30 minutes** depending on video length + transcript size. Users currently have two ways to track progress:

1. **Pull-to-refresh on 我的 → 导入队列** view. Manual, no notification.
2. **Wait for the entry to appear in Library** when the desktop finishes the round-trip + syncs. No mid-flight visibility.

Both miss the window during the long async wait where the user has handed work to the system and **wants ambient confirmation it's still alive**. Live Activities — Dynamic Island + lock-screen card, both refreshable via APNs without the app foregrounded — are the natural surface for this.

This is Tier 1 of a broader Live Activity strategy:
- **Tier 1 (this doc)**: desktop import queue progress.
- **Tier 2 (deferred)**: long subtitle extractions / OSS uploads from inside the app.

Tier 2 stays deferred until Tier 1's APNs plumbing is proven.

---

## 2. Decisions

Recorded from the prior brainstorm session, in priority order:

### 2.1 Update mechanism: **APNs push** (vs. polling, vs. foreground-only)

| Option | Picked? | Reasoning |
|---|---|---|
| **A — Polling from the app** | ❌ | App needs to be foregrounded to poll. Defeats the "ambient check-in" point of an Activity. |
| **B — APNs push** | ✅ | Backend already knows when queue state changes (worker writes `status` to `import_queue` rows). One outbound APNs HTTP/2 call per state change → ContentState updates without app interaction. |
| **C — Background fetch + local update** | ❌ | iOS schedules background fetch opportunistically, latency is anywhere from 10s to never. Useless for "show me right now". |

### 2.2 Activity scope: **single aggregate Activity per device** (vs. one per item)

A single Activity tracks the user's overall queue health:

```
inProgress: 2   completed: 5   failed: 1
recentTitle: "How to Pour-Over Coffee"   ← most-recently-changed item
```

vs. one Activity per imported item, which would:
- Crowd Dynamic Island with 4-5 dots for power users.
- Multiply APNs cost 4-5x.
- Confuse the system Activity manager (iOS prioritizes the most-recent Activity for Dynamic Island compact mode — old ones evict the new one's view).

Aggregate is the cleaner mental model and the cheaper implementation.

### 2.3 Tap routing: **smart, based on aggregate state**

| State | Tap destination |
|---|---|
| All items done/failed | `whatsub://library` (the freshly-synced entries are there) |
| Any items in progress | `whatsub://import-queue` (the user wants to see *what's* still running) |

The Activity's `widgetURL()` carries one of these two URLs based on `inProgress > 0`.

### 2.4 Auto-end: **10 minutes after all items reach a terminal state**

Once `inProgress == 0`, the Activity transitions to a "done" visual state (green check, "已完成") and a 10-min countdown begins. After 10 min the main app's foreground `.onAppear` calls `Activity.end(.dismissalPolicy(.default))`. We don't end immediately because:

- Users glance at lock screen for closure ("did it finish?"). Premature end means glance shows nothing.
- 10 min is the system-soft-dismiss anyway — leaving it shorter saves nothing.

If the user backgrounds the app for >10 min after all-done, the next foregrounding ends the Activity. If they leave the app backgrounded for hours, iOS's 8-hour cap on Activities terminates it (graceful, no action needed).

---

## 3. Architecture

### 3.1 Backend changes (`whatsub-license`)

Seven items, all small and additive — no schema breakage.

#### 3.1.1 New table `live_activity_tokens`

```sql
CREATE TABLE live_activity_tokens (
  email          TEXT NOT NULL,
  push_token     TEXT NOT NULL,
  activity_id    TEXT NOT NULL,           -- iOS Activity instance id (UUID)
  registered_at  BIGINT NOT NULL,
  expires_at     BIGINT NOT NULL,         -- iOS hands us a ttl; default 8h from registered_at
  PRIMARY KEY (email, activity_id)
);
CREATE INDEX live_activity_tokens_email_idx ON live_activity_tokens (email);
```

One row per active Activity. A user can have multiple devices (iPhone + iPad) → multiple rows per email → backend fan-outs the push.

#### 3.1.2 New endpoint: `POST /api/live-activity/register`

```typescript
// body: { activityId: string, pushToken: string, expiresAt: number }
// auth: requireSession (same as the rest of /api)
// behavior: UPSERT into live_activity_tokens. Idempotent — iOS sends every
//           bind; we just overwrite.
```

#### 3.1.3 New endpoint: `POST /api/live-activity/end`

```typescript
// body: { activityId: string }
// auth: requireSession
// behavior: DELETE the row. Used when iOS Activity.end() runs so we stop
//           pushing to a dead token.
```

#### 3.1.4 New module `src/lib/apnsPush.ts`

Thin wrapper over Apple's HTTP/2 APNs endpoint (`api.push.apple.com` for production, `api.development.push.apple.com` for sandbox/TestFlight). Authenticated via JWT signed with the team's APNs `.p8` key. **Topic must be `cc.eversay.whatsub.mobile.push-type.liveactivity`** — that's the Activity-specific topic format.

Payload shape for an update:

```json
{
  "aps": {
    "timestamp": 1734567890,
    "event": "update",
    "content-state": {
      "inProgress": 2,
      "completed": 5,
      "failed": 1,
      "recentTitle": "How to Pour-Over Coffee"
    },
    "stale-date": 1734571490
  }
}
```

For an end:
```json
{
  "aps": {
    "timestamp": 1734567890,
    "event": "end",
    "content-state": { /* final state */ },
    "dismissal-date": 1734568490
  }
}
```

#### 3.1.5 Db side-effect hooks in `import_queue` mutations

Every place `db.ts` currently updates an `import_queue` row's `status` field, we add **after the update**:

```typescript
await pushQueueStateForEmail(this, email, /* recentTitle */ title);
```

`pushQueueStateForEmail`:
1. Counts `import_queue` rows for `email` grouped by status → `{ pending, processing, completed, failed }`.
2. Maps to ContentState: `inProgress = pending + processing`, `completed`, `failed`, `recentTitle`.
3. Reads all `live_activity_tokens` for that email.
4. For each token → calls `apnsPush.update(...)`.
5. **Best-effort**: APNs failure logs but doesn't fail the originating DB mutation. We retry on the next state change.

Two mutation sites today:
- `enqueueImport` (status='pending' on insert)
- `setImportQueueStatus` (status update by desktop client)

A third site will appear later if/when we add "claimed by worker" tracking — same hook applies.

#### 3.1.6 Title backfill helper

ContentState carries `recentTitle?: string` so the Activity card can show *what* finished/failed. For `enqueueImport` we have the title at insert time (the user's pasted URL or, post-fetch, the resolved YT/B站 title). For `setImportQueueStatus` we need to look up the row first:

```typescript
async getImportQueueTitle(id: string): Promise<string | null> {
  // SELECT title FROM import_queue WHERE id = $1
}
```

One additional query per state change — cheap.

#### 3.1.7 Env vars

```env
APNS_KEY_ID=<10-char>
APNS_TEAM_ID=Q3BK52FQT9
APNS_KEY_P8=<base64 PEM>
APNS_TOPIC=cc.eversay.whatsub.mobile.push-type.liveactivity
APNS_ENVIRONMENT=production    # set to "development" for sandbox/TestFlight
```

Per `CLAUDE.md`'s "踩过的坑" entry on Aliyun docker-compose env: these vars must be listed in `services.whatsub-license.environment:` in `docker-compose.yml`, not just `.env`. Otherwise the container won't see them.

`APNS_ENVIRONMENT` is the only switch that needs care during App Store rollout: TestFlight builds want `development`, App Store distributed builds want `production`. The wrapper picks the host URL from this var; the JWT + topic are the same in both.

**Estimated backend work: 1.5-2 days.**

### 3.2 iOS Widget Extension target

#### 3.2.1 New `whatsub-widget/` target in `project.yml`

```yaml
whatsub-widget:
  type: app-extension
  platform: iOS
  deploymentTarget: "16.1"
  sources:
    - whatsub-widget
    - whatsub-mobile/Shared/ImportActivityAttributes.swift   # shared with main
    - whatsub-mobile/App/Theme.swift                          # shared brand colors
  info:
    path: whatsub-widget/Info.plist
    properties:
      NSExtension:
        NSExtensionPointIdentifier: com.apple.widgetkit-extension
```

This mirrors the existing `whatsub-share/` Share Extension setup — same pattern of sources-shared-across-targets via explicit listing.

#### 3.2.2 Shared `ImportActivityAttributes`

New file `whatsub-mobile/Shared/ImportActivityAttributes.swift`, compiled into both `whatsub-mobile` (main) and `whatsub-widget` (extension):

```swift
import ActivityKit

struct ImportActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let inProgress: Int
        let completed: Int
        let failed: Int
        let recentTitle: String?
    }
    /// Immutable per-Activity context. Used for the tap-deep-link's
    /// `widgetURL` query so we can confirm "this Activity belongs to
    /// this user" on resume in case the user switched accounts.
    let userEmail: String
}
```

#### 3.2.3 Widget configuration

`whatsub-widget/ImportActivityWidget.swift`:

```swift
import WidgetKit
import SwiftUI
import ActivityKit

struct ImportActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ImportActivityAttributes.self) { context in
            // Lock-screen card (always visible when Activity is live)
            LockScreenCard(state: context.state)
                .padding(16)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { /* icon */ }
                DynamicIslandExpandedRegion(.trailing) { /* count badge */ }
                DynamicIslandExpandedRegion(.center) { /* progress bar + title */ }
                DynamicIslandExpandedRegion(.bottom) { /* "查看详情" hint */ }
            } compactLeading: {
                Image(systemName: "tray.and.arrow.down.fill")
            } compactTrailing: {
                Text("\(context.state.inProgress)")
            } minimal: {
                Text("\(context.state.inProgress)")
            }
            .widgetURL(URL(string: tapDestination(context.state)))
        }
    }

    /// Smart routing: in-progress → import-queue, done → library.
    private func tapDestination(_ state: ImportActivityAttributes.ContentState) -> String {
        state.inProgress > 0
            ? "whatsub://import-queue"
            : "whatsub://library"
    }
}
```

#### 3.2.4 Visual layouts

**Compact** (Dynamic Island default):
```
[📥]              [3]
```
Icon left, in-progress count right. Updates seamlessly on each push.

**Minimal** (when another Activity has focus):
```
[3]
```
Just the count — fits in the < 24pt icon slot.

**Expanded** (long-press / pull-down):
```
┌────────────────────────────────────┐
│ 📥  视频导入处理中             3/8 │
│ ████████░░░░░░░░░░░░░░░░░░░░░░░░░  │
│ "How to Pour-Over Coffee"          │
│                                    │
│ 点击查看 →                          │
└────────────────────────────────────┘
```

**Lock-screen card** (full layout, all devices iOS 16.1+):
```
┌──────────────────────────────────────┐
│ 📥 视频导入处理                       │
│ ────────────────────────────────────  │
│  进行中 2  ·  完成 5  ·  失败 1       │
│  最近：How to Pour-Over Coffee        │
└──────────────────────────────────────┘
```

When all done:
```
✓ 全部完成 (8/8) — 点击查看 Library
```

When failed > 0:
```
⚠ 部分失败 (1) — 点击查看队列详情
```

### 3.3 iOS main app integration

#### 3.3.1 New `App/LiveActivityCoordinator.swift`

```swift
@MainActor
final class LiveActivityCoordinator: ObservableObject {
    static let shared = LiveActivityCoordinator()

    /// Currently-tracked Activity. nil if no in-flight pushes.
    private var currentActivity: Activity<ImportActivityAttributes>?
    private var pushTokenTask: Task<Void, Never>?

    /// Called when the user enqueues an import (first push of the session).
    /// Starts the Activity if none exists, otherwise updates the existing one.
    func ensureActivity(forUserEmail email: String, initialState: ImportActivityAttributes.ContentState) {
        if let existing = currentActivity, existing.activityState == .active {
            // Already running — backend will push the new state.
            return
        }
        let attributes = ImportActivityAttributes(userEmail: email)
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: nil),
                pushType: .token
            )
            currentActivity = activity
            // Listen for the push token Apple gives us; ship it to backend.
            pushTokenTask = Task { [weak self] in
                for await tokenData in activity.pushTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    await self?.registerToken(hex, activityId: activity.id, email: email)
                }
            }
        } catch {
            // Common reasons: user denied permission, push not entitled, etc.
            // We silently fall back to no-Activity. Import queue still works
            // via the existing 我的 → 导入队列 manual surface.
        }
    }

    /// Called on app foreground when allDone + 10min elapsed (see §2.4).
    func endIfStale() async {
        guard let activity = currentActivity else { return }
        if activity.content.state.inProgress == 0,
           let lastChange = lastTerminalTimestamp(),
           Date().timeIntervalSince1970 - lastChange > 600 {
            await activity.end(activity.content, dismissalPolicy: .default)
            await unregisterToken(activityId: activity.id)
            currentActivity = nil
        }
    }

    private func registerToken(_ hex: String, activityId: String, email: String) async { /* POST */ }
    private func unregisterToken(activityId: String) async { /* POST */ }
    private func lastTerminalTimestamp() -> Double? { /* stored in UserDefaults */ }
}
```

#### 3.3.2 Hook into the existing import push site

`ImportViewModel.pushToDesktop(token:)` already POSTs `/api/library/import-queue`. Right after the successful response:

```swift
let initialState = await WhatsubAPI.shared.queueState(token: token) // existing or new endpoint
await LiveActivityCoordinator.shared.ensureActivity(
    forUserEmail: appState.session?.email ?? "",
    initialState: initialState
)
```

`queueState` returns the current `{ inProgress, completed, failed, recentTitle }` — a small endpoint we'd also use for the manual 导入队列 view's initial paint. Existing or new, low cost.

#### 3.3.3 Deep link routing

The Activity's `widgetURL` opens `whatsub://import-queue` or `whatsub://library`. `WhatsubMobileApp.scenePhase + .onOpenURL` already handles `whatsub://import?url=…` from the Share Extension; we extend the same handler to recognize `whatsub://import-queue` (navigate to MeView → 导入队列) and `whatsub://library` (switch to Library tab).

#### 3.3.4 Foreground hygiene

```swift
.onChange(of: scenePhase) { phase in
    if phase == .active {
        Task { await LiveActivityCoordinator.shared.endIfStale() }
    }
}
```

**Estimated iOS work: 1.5-2 days** (target + shared file plumbing + Activity lifecycle + deep linking + visual polish).

### 3.4 Data flow (end-to-end)

```
[user taps "推送到桌面端"]
  ↓
ImportViewModel.pushToDesktop
  ↓
POST /api/library/import-queue (existing)
  ↓
Backend INSERT INTO import_queue (status='pending')
  ↓
pushQueueStateForEmail (new hook — §3.1.5)
  ↓
APNs HTTP/2 to api.push.apple.com — payload: aps.event=update
  ↓
iOS WidgetKit receives update; Activity's ContentState mutates
  ↓
Dynamic Island compact view re-renders: tray icon + count badge
  ↓
[5-30 min later, desktop worker completes one item]
  ↓
Desktop POSTs /api/library/import-queue/:id/status (existing)
  ↓
Backend UPDATE import_queue SET status='completed'
  ↓
pushQueueStateForEmail again — new ContentState
  ↓
APNs → iOS — Activity updates
  ↓
[user taps Dynamic Island]
  ↓
widgetURL "whatsub://library" (smart routing: inProgress==0)
  ↓
WhatsubMobileApp.onOpenURL → switch to Library tab
  ↓
[10 min idle on all-done]
  ↓
LiveActivityCoordinator.endIfStale fires on next foregrounding
  ↓
Activity.end → APNs aps.event=end → iOS dismisses
  ↓
DELETE from live_activity_tokens
```

---

## 4. Error handling

### 4.1 Push permission denied

`Activity.request` doesn't itself require notification permission, but APNs delivery does. If the user denied push permission at install time, iOS rejects our APNs deliveries silently. The Activity will still **show**, but it'll stay frozen on the initial state until the app's next foreground update (we'll add a manual `Activity.update` call on `.onAppear` of the import queue view as a fallback nudge).

Fallback copy in the Lock Screen card when stale:
```
ⓘ 离线状态 — 打开 app 查看实时进度
```

### 4.2 8-hour Activity cap

iOS enforces an 8-hour wall-clock lifetime on every Activity. If a user enqueues at hour 0 and walks away, the Activity automatically dies at hour 8 even with `inProgress > 0`. Our handling:

- The Activity dies → APNs pushes start returning errors (we don't catch them; backend logs).
- Next time the user foregrounds the app, `LiveActivityCoordinator.ensureActivity` re-creates a fresh Activity with the current state.
- The `live_activity_tokens` row from the dead Activity will be UPSERT-overwritten with the new token at `register` time.

No explicit cleanup needed for the dead row beyond the next overwrite; the row carries `expires_at` (set at register time = now + 8h) so an eventual janitor sweep can purge truly-stale ones if we want.

### 4.3 Network failures on APNs send

Hidden inside the best-effort wrapper — log + drop. The next state change re-sends the full snapshot, so a missed push self-heals on the next change.

### 4.4 Conflicting state (multiple devices)

The same email can have iPhone + iPad. Both get their own `live_activity_tokens` row + their own push fan-out. They both receive the same ContentState — fine, the count is global per email.

If the user enqueues on the iPhone, the iPad's Activity also starts the next time the iPad app forgrounds (its `LiveActivityCoordinator.ensureActivity` sees an active push state and bootstraps).

### 4.5 Race: user dismisses Activity before all done

iOS allows the user to swipe away the lock-screen card. Our `LiveActivityCoordinator` doesn't actively listen for dismissal (no API for it on the main app side), but `Activity.activityState` reflects it on next access. We treat dismissed-but-still-in-flight as "user opted out for this session" — we don't re-start an Activity for the same import until the user enqueues a NEW item.

---

## 5. Testing strategy

### 5.1 Simulator

iOS Simulator **does support Live Activity** as of Xcode 14.1, but there's no Dynamic Island simulation — only the lock-screen card. Sufficient for visual verification of layouts + state transitions. APNs pushes work in simulator via `xcrun simctl push <device> <bundle-id> payload.json` — no real APNs needed for end-to-end visuals.

### 5.2 Device

Required for Dynamic Island. The Internal Test group (`2216681472@qq.com`) installs the TestFlight build on an iPhone 14 Pro+ and we exercise:

- Enqueue → Activity starts within 2s.
- Backend pushes hit the device within 1-3s of the DB mutation.
- Tap routing works (all-done → Library, in-progress → 导入队列).
- 10-min auto-end fires on next foreground.
- 8-hour cap behavior (manual: hold for 8 hours, foreground → restart).

### 5.3 What can't be tested in CI

The whole APNs round-trip. CI builds the app and uploads to TestFlight; **physical-device + push delivery is the only way to verify the wire**. The risk is real but bounded by the visual surface (worst case: nothing shows; users fall back to the existing 我的 → 导入队列 view).

---

## 6. Non-goals

- **No Lock Screen widget for Library** — that's a separate WidgetKit static widget, not an Activity. Different APIs, different lifecycle. Out of scope.
- **No multiple parallel Activities** — see §2.2. We commit to the aggregate model.
- **No iOS 16.0 support for this feature** — Activity requires 16.1. Users on 16.0 get the existing in-app queue view, unchanged.
- **No PiP integration** — `BackgroundAudioCoordinator` and PiP are unrelated to import queue tracking.
- **No subtitle-extraction tier 2** — separate spec, separate plan.

---

## 7. Open questions resolved during brainstorm

| Question | Resolution |
|---|---|
| Per-item Activity vs. aggregate? | Aggregate (§2.2) |
| Polling vs. push? | Push (§2.1) |
| When does Activity end? | 10 min after all done (§2.4) |
| What does tap do? | Smart routing based on state (§2.3) |
| Will this require new desktop work? | **No** — desktop already posts state changes to backend; backend is the choke point. |
| Will this require backend work? | **Yes** — 7 items in §3.1, est. 1.5-2 days. |

---

## 8. Total estimate

| Component | Days |
|---|---|
| Backend (§3.1) | 1.5-2 |
| iOS Widget Extension + main-app integration (§3.2 + §3.3) | 1.5-2 |
| Testing on physical device + iteration | 0.5-1 |
| ASC review notes preamble for the new entitlements (push) | 0.25 |
| **Total** | **~4-5 days** |

Implementation plan to follow (writing-plans skill).
