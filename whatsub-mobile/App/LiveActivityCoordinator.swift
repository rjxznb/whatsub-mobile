import Foundation
import ActivityKit
import UIKit

/// Owns the single in-flight `Activity<ImportActivityAttributes>` for the
/// desktop import-queue Live Activity (2026-06-18 plan). Process-wide
/// singleton because:
///   1. iOS surfaces ONE Activity per attributes-type per app at a time on
///      the Dynamic Island / lock screen — per-view instances would race.
///   2. The APNs push-token listener must outlive whichever screen kicked
///      off the import (user may background the app, switch tabs, etc.);
///      a static singleton survives that.
///
/// Lifecycle:
///   ① Caller (e.g. ImportQueueViewModel) → `ensureActivity(forUserEmail:initialState:)`
///     when the first pending/processing item appears.
///   ② We start `Activity.request(pushType: .token)`. iOS asynchronously
///     hands back the APNs push token via `activity.pushTokenUpdates`; we
///     await each token in a long-lived `Task` and POST it to the backend
///     so the server can fan out ContentState updates.
///   ③ Backend pushes ContentState dictionaries via APNs HTTP/2; the OS
///     applies them to the live Activity — no client code needed for
///     mid-flight updates (the widget extension renders the new state).
///   ④ On foreground, caller pings `endIfStale()`. Two-phase 10-min latch:
///     first call after `inProgress == 0` records the timestamp, second
///     call ≥600s later ends the Activity + tells the backend to forget
///     the push token. Any item flipping back to in-progress resets the
///     latch (`allDoneAt = nil`).
///
/// Auth-token access mirrors `ChatCompletionsClient` / `StoreManager`:
/// we read the bearer straight from Keychain via `KeychainStore.load()`
/// — the coordinator is decoupled from `AppState`, which is fine because
/// the Activity only exists when the user is signed in (caller-enforced).
// 2026-06-19 — App-wide deployment target is iOS 16.0 but ActivityKit's
// `Activity<...>` only ships on 16.1+. Gating the whole coordinator
// at 16.1 keeps every Activity-touching line behind a single guard;
// callers gate their invocations with `if #available(iOS 16.1, *)`.
@available(iOS 16.1, *)
@MainActor
final class LiveActivityCoordinator: ObservableObject {

    static let shared = LiveActivityCoordinator()
    private init() {}

    /// Currently-running Activity, if any. Cleared on `endIfStale()` once
    /// the 10-min cooldown elapses.
    private var currentActivity: Activity<ImportActivityAttributes>?

    /// Long-lived listener for the OS push token. Cancelled when we tear
    /// the Activity down so it doesn't leak past the Activity's lifetime.
    private var pushTokenTask: Task<Void, Never>?

    /// Wall-clock seconds (since 1970) when `inProgress` first hit zero
    /// during a polling sweep. We hold the Activity another 10 min after
    /// this so the user has a chance to see the "completed" state on the
    /// lock screen instead of it vanishing the instant the last item
    /// finishes. Reset to nil if anything flips back to in-progress
    /// (retry, new item enqueued) or after a successful tear-down.
    private var allDoneAt: Double?

    // MARK: - Public API

    /// Idempotent: if an Activity is already live, return immediately.
    /// Otherwise request a fresh one and start the push-token listener.
    func ensureActivity(
        forUserEmail email: String,
        initialState: ImportActivityAttributes.ContentState
    ) async {
        if let existing = currentActivity, existing.activityState == .active {
            return
        }
        // OS-level kill switch (user disabled Live Activities for the app
        // in Settings, Focus mode hides them, low-power mode in some
        // configs, etc.). Bail silently — caller has nothing to do.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = ImportActivityAttributes(userEmail: email)
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: nil),
                pushType: .token
            )
            currentActivity = activity

            // Cancel any prior listener defensively — in normal flow it's
            // nil here, but if the OS ever delivered an Activity-state we
            // missed, this prevents two listeners from fighting.
            pushTokenTask?.cancel()
            pushTokenTask = Task { [weak self] in
                for await tokenData in activity.pushTokenUpdates {
                    // ActivityKit can rotate the token mid-session (rare).
                    // We re-POST each value — server is upsert-keyed by
                    // activityId so the latest one wins.
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    await self?.uploadToken(hex, activityId: activity.id, email: email)
                }
            }
        } catch {
            // .request can fail when the user has hit the per-app Activity
            // budget (iOS caps concurrent Activities per attributes type)
            // or when push entitlement isn't in the provisioning profile.
            // Logging is enough — the import flow still works without the
            // lock-screen card; it's a "nice to have" enhancement.
            print("[LiveActivity] request failed: \(error)")
        }
    }

    /// Drive the two-phase cooldown latch. Caller should invoke this each
    /// time the foreground import-queue poll completes (i.e. on every
    /// `ImportQueueViewModel.load()` finish + on `.scenePhase == .active`).
    /// Cheap when there's no Activity (early-return).
    func endIfStale() async {
        guard let activity = currentActivity else { return }
        let state = activity.content.state
        if state.inProgress == 0 {
            let now = Date().timeIntervalSince1970
            if let start = allDoneAt {
                if now - start > 600 {
                    await activity.end(activity.content, dismissalPolicy: .default)
                    await uploadEnd(activityId: activity.id)
                    pushTokenTask?.cancel()
                    pushTokenTask = nil
                    currentActivity = nil
                    allDoneAt = nil
                }
            } else {
                // First sweep with no in-flight work — arm the latch.
                allDoneAt = now
            }
        } else {
            // Something is in-flight again (retry, new enqueue, push delivered
            // a fresh inProgress count). Disarm the latch so we restart the
            // 10-min window when work next drains to zero.
            allDoneAt = nil
        }
    }

    // MARK: - Backend round trips

    /// POST the freshly-minted push token to the backend so it can fan out
    /// ContentState updates. Bearer comes from Keychain directly — the
    /// coordinator is intentionally decoupled from `AppState` so it can
    /// run in background contexts (the OS may deliver `pushTokenUpdates`
    /// outside a SwiftUI view tree).
    private func uploadToken(_ hex: String, activityId: String, email: String) async {
        guard let token = KeychainStore.load()?.sessionToken else {
            print("[LiveActivity] no session token — skipping register")
            return
        }
        do {
            try await WhatsubAPI.shared.registerLiveActivityToken(
                activityId: activityId,
                pushToken: hex,
                token: token
            )
        } catch {
            // Best-effort: if the register fails the Activity stays up
            // but won't get push updates. The 10-min cooldown will end
            // it eventually. No user-facing surface needed.
            print("[LiveActivity] register failed: \(error)")
        }
    }

    /// Tell the backend the Activity is over so it stops trying to push
    /// to the (about-to-be-invalidated) token.
    private func uploadEnd(activityId: String) async {
        guard let token = KeychainStore.load()?.sessionToken else {
            print("[LiveActivity] no session token — skipping end")
            return
        }
        do {
            try await WhatsubAPI.shared.endLiveActivity(
                activityId: activityId,
                token: token
            )
        } catch {
            // Backend should also expire stale tokens on its own (next
            // failed APNs delivery) — losing this call doesn't leak
            // anything user-visible.
            print("[LiveActivity] end failed: \(error)")
        }
    }
}
