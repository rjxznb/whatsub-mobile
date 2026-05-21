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

    private let emailRegex = try! NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#)

    private func emailValid(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return emailRegex.firstMatch(in: s, range: range) != nil
    }

    func sendCode() async {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard emailValid(trimmed) else { errorMessage = "邮箱格式不对"; return }
        busy = true; errorMessage = nil
        do {
            try await WhatsubAPI.shared.sendCode(email: trimmed)
            email = trimmed
            step = .code
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
    }
}
