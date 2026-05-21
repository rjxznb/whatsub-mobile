import Foundation
import SwiftUI

@MainActor
final class AuthViewModel: ObservableObject {
    enum Step { case email, code }

    @Published var step: Step = .email
    @Published var email: String = ""
    @Published var code: String = ""
    @Published var busy = false
    @Published var error: String?

    private let emailRegex = try! NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#)

    private func emailValid(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return emailRegex.firstMatch(in: s, range: range) != nil
    }

    func sendCode() async {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard emailValid(trimmed) else { error = "邮箱格式不对"; return }
        busy = true; error = nil
        do {
            try await WhatsubAPI.shared.sendCode(email: trimmed)
            email = trimmed
            step = .code
        } catch let e as APIError {
            error = e.chinese
        } catch {
            error = "发送失败，请重试"
        }
        busy = false
    }

    /// Returns the Session on success so the caller (AuthGateView) can hand it
    /// to AppState. Returns nil on failure (error is published).
    func verify() async -> Session? {
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            error = "请输入 6 位数字验证码"; return nil
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let s = try await WhatsubAPI.shared.verifyCode(email: email, code: code)
            return s
        } catch let e as APIError {
            error = e.chinese; return nil
        } catch {
            error = "验证失败，请重试"; return nil
        }
    }

    func backToEmail() {
        step = .email
        code = ""
        error = nil
    }
}
