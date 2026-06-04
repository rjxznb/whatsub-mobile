import Foundation

/// Central URL builder. Bases differ because nginx routes them differently:
/// - auth + iap live under /api/license/* (nginx /api/license/ → backend /api/*)
/// - corpus + library are verbatim /api/corpus/* and /api/library/*
enum Endpoints {
    static let authBase = "https://whatsub.eversay.cc/api/license/auth"
    static let iapBase = "https://whatsub.eversay.cc/api/license/iap"
    static let corpusBase = "https://whatsub.eversay.cc/api/corpus"
    static let libraryBase = "https://whatsub.eversay.cc/api/library"
    /// Managed-LLM relay (2026-06-04). `/api/llm/v1/chat/completions`
    /// pretends to be an openai-compatible vendor; `/api/llm/quota`
    /// returns the per-period budget snapshot.
    static let llmBase = "https://whatsub.eversay.cc/api/llm"
    /// The openai-compatible base URL clients embed into LlmSettings when
    /// "whatsub 托管" is on — same host, includes the `/v1` segment so
    /// `${baseUrl}/chat/completions` resolves to the proxy.
    static let llmRelayClientBase = "https://whatsub.eversay.cc/api/llm/v1"

    static func auth(_ path: String) -> URL { URL(string: "\(authBase)/\(path)")! }
    static func iap(_ path: String) -> URL { URL(string: "\(iapBase)/\(path)")! }
    static func corpus(_ path: String) -> URL { URL(string: "\(corpusBase)/\(path)")! }
    static func library(_ path: String) -> URL { URL(string: "\(libraryBase)/\(path)")! }
    static func llm(_ path: String) -> URL { URL(string: "\(llmBase)/\(path)")! }
}
