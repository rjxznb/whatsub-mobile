import Foundation

// ----- Auth -----

struct SendCodeRequest: Encodable { let email: String }

struct VerifyCodeRequest: Encodable {
    let email: String
    let code: String
}

struct VerifyCodeResponse: Decodable {
    let sessionToken: String
    let expiresAt: Int64
}

struct MeResponse: Decodable {
    let email: String
    let hasActiveLicense: Bool
    let isAdmin: Bool?
}

/// Generic `{ ok: true }` or `{ error: "..." }` envelope used by several routes.
struct OkResponse: Decodable { let ok: Bool? }
struct ErrorResponse: Decodable { let error: String? }
