import Foundation
import SwiftUI

@MainActor
final class AuthViewModel: ObservableObject {
    enum Step { case email, code }

    @Published var step: Step = .email
    @Published var email: String = ""
    @Published var code: String = ""
    @Published var busy = false
    // NOTE: named `errorMessage`, NOT `error` — a bare `catch {}` block binds
    // an implicit immutable constant `error`, which shadows a property named
    // `error` and makes `error = ...` fail to compile ("error is immutable").
    @Published var errorMessage: String?
    /// Earliest time the next sendCode call is allowed. Set when a send
    /// succeeds (local 30 s soft cooldown — prevents users from ever tripping
    /// the server's 2/min limit in normal use) OR when the server returns
    /// 429 (Retry-After driven). The view ticks UI off Date.now via a
    /// TimelineView so this doesn't need its own timer here.
    @Published var sendBlockedUntil: Date?

    /// Local soft-cooldown after a successful send. Keep this strictly
    /// SHORTER than the server's per-email-minute window (60 s) — server
    /// allows 2/min, so 30 s lets the user re-request once if they truly
    /// need to, without tripping the real 429.
    private let softCooldownSec: TimeInterval = 30

    private let emailRegex = try! NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#)

    private func emailValid(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return emailRegex.firstMatch(in: s, range: range) != nil
    }

    /// Seconds until sendCode is allowed again. Read by the view inside a
    /// TimelineView so it ticks every second.
    func sendRetrySeconds(at now: Date) -> Int {
        guard let blockedUntil = sendBlockedUntil else { return 0 }
        return max(0, Int(blockedUntil.timeIntervalSince(now).rounded(.up)))
    }

    func sendCode() async {
        // Belt-and-suspenders client-side guard: if the view button is wired
        // correctly this never fires, but if something else calls this while
        // cooled-down we still respect the lockout.
        if let blockedUntil = sendBlockedUntil, blockedUntil > Date() { return }

        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard emailValid(trimmed) else { errorMessage = "邮箱格式不对"; return }
        busy = true; errorMessage = nil
        do {
            try await WhatsubAPI.shared.sendCode(email: trimmed)
            email = trimmed
            step = .code
            // Local soft cooldown — prevents the user from spamming the
            // button hard enough to hit the server's 2/min limit.
            sendBlockedUntil = Date().addingTimeInterval(softCooldownSec)
        } catch APIError.rateLimited(_, let retryAfterSec, let message) {
            errorMessage = message
            sendBlockedUntil = Date().addingTimeInterval(TimeInterval(retryAfterSec))
        } catch let e as APIError {
            errorMessage = e.chinese
        } catch {
            errorMessage = "发送失败，请重试"
        }
        busy = false
    }

    /// Returns the Session on success so the caller (AuthGateView) can hand it
    /// to AppState. Returns nil on failure (errorMessage is published).
    func verify() async -> Session? {
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            errorMessage = "请输入 6 位数字验证码"; return nil
        }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let s = try await WhatsubAPI.shared.verifyCode(email: email, code: code)
            return s
        } catch APIError.rateLimited(_, let retryAfterSec, let message) {
            // For verify rate limits we don't lock the SEND button — the user
            // hit the verify ceiling, sending a new code won't help them. We
            // just surface the message; verify button will simply 429 again
            // until the hour rolls.
            errorMessage = "\(message)（\(retryAfterSec) 秒后可重试）"
            return nil
        } catch let e as APIError {
            errorMessage = e.chinese; return nil
        } catch {
            errorMessage = "验证失败，请重试"; return nil
        }
    }

    func backToEmail() {
        step = .email
        code = ""
        errorMessage = nil
        // Cooldown sticks across the back nav — the email-minute window is
        // server-side and doesn't reset when the user navigates.
    }
}
