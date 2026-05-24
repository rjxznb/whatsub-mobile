import Foundation

/// Central URL builder. Bases differ because nginx routes them differently:
/// - auth + iap live under /api/license/* (nginx /api/license/ → backend /api/*)
/// - corpus + library are verbatim /api/corpus/* and /api/library/*
enum Endpoints {
    static let authBase = "https://whatsub.eversay.cc/api/license/auth"
    static let iapBase = "https://whatsub.eversay.cc/api/license/iap"
    static let corpusBase = "https://whatsub.eversay.cc/api/corpus"
    static let libraryBase = "https://whatsub.eversay.cc/api/library"

    static func auth(_ path: String) -> URL { URL(string: "\(authBase)/\(path)")! }
    static func iap(_ path: String) -> URL { URL(string: "\(iapBase)/\(path)")! }
    static func corpus(_ path: String) -> URL { URL(string: "\(corpusBase)/\(path)")! }
    static func library(_ path: String) -> URL { URL(string: "\(libraryBase)/\(path)")! }
}
