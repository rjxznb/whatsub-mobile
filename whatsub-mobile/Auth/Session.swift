import Foundation

/// A logged-in session. Persisted in Keychain; mirrors the backend's
/// verify-code response + the email used to obtain it.
struct Session: Codable, Equatable {
    let email: String
    let sessionToken: String
    /// Unix ms (matches the backend's `expiresAt`).
    let expiresAt: Int64

    var isValid: Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return expiresAt > nowMs
    }
}
