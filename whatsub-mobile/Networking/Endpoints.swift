import Foundation

/// Central URL builder. Three bases because nginx routes them differently:
/// - auth lives under /api/license/auth/* (nginx strips /license → backend /api/auth/*)
/// - corpus + library are verbatim /api/corpus/* and /api/library/*
enum Endpoints {
    static let authBase = "https://whatsub.eversay.cc/api/license/auth"
    static let corpusBase = "https://whatsub.eversay.cc/api/corpus"
    static let libraryBase = "https://whatsub.eversay.cc/api/library"

    static func auth(_ path: String) -> URL { URL(string: "\(authBase)/\(path)")! }
    static func corpus(_ path: String) -> URL { URL(string: "\(corpusBase)/\(path)")! }
    static func library(_ path: String) -> URL { URL(string: "\(libraryBase)/\(path)")! }
}
