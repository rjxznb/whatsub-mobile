import Foundation
import ActivityKit

/// Shared between the main app (`whatsub-mobile`) and the Widget Extension
/// (`whatsub-widget`). Both targets compile this file via project.yml's
/// per-target `sources:` list — same pattern as AppGroup.swift.
///
/// ContentState is what backend pushes to APNs and what the Widget UI
/// reads. The outer ActivityAttributes (`userEmail`) is fixed for the
/// lifetime of an Activity instance and not mutated by pushes — only used
/// for diagnostics on resume.
///
/// See `docs/superpowers/plans/2026-06-18-ios-live-activity-import-queue.md`.
struct ImportActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public let inProgress: Int
        public let completed: Int
        public let failed: Int
        public let recentTitle: String?

        public init(inProgress: Int, completed: Int, failed: Int, recentTitle: String?) {
            self.inProgress = inProgress
            self.completed = completed
            self.failed = failed
            self.recentTitle = recentTitle
        }
    }

    public let userEmail: String

    public init(userEmail: String) {
        self.userEmail = userEmail
    }
}
