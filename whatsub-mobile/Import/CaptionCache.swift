import Foundation

/// Per-video disk cache for YouTube caption extraction results.
///
/// Layout: `<directory>/<videoId>.json` — one file per video. Each file
/// is a small JSON object (`version`, `videoId`, `cachedAt`, `cues`,
/// `durationSec`). Version 1 files had cues only; they remain readable and are
/// marked for one player-metadata refresh. Version 2 records that metadata was
/// queried even when YouTube omitted duration, preventing endless refreshes.
/// Per-video files were chosen over a single index because:
///   1. Atomic writes per-video (no merge contention if the user opens
///      two videos in parallel — the second write doesn't have to read
///      and rewrite a shared index).
///   2. O(1) reads — no parse of unrelated cached videos.
///   3. iOS's cache eviction can purge individual files cleanly when
///      storage is tight.
///
/// Eviction: there is no TTL (spec §5.3). Files are removed by
/// `clearAll()`, by iOS itself under storage pressure (the directory
/// lives under `~/Library/Caches/` which iOS may sweep), or by a future
/// schema version bump (unknown `version` is rejected on read, so old
/// entries become invisible without an explicit purge step).
///
/// Spec source: `docs/superpowers/specs/2026-06-19-ios-innertube-captions-design.md` §5.
final class CaptionCache {

    static let shared = CaptionCache()

    private let directory: URL
    private let lock = NSLock()
    struct Entry {
        let result: CaptionExtractionResult
        let needsMetadataRefresh: Bool
    }

    private let currentVersion = 2

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory,
                                                  in: .userDomainMask)[0]
            self.directory = caches.appendingPathComponent("yt_captions",
                                                           isDirectory: true)
        }
    }

    func get(_ videoId: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return load(videoId)
    }

    private func load(_ videoId: String) -> Entry? {
        let path = directory.appendingPathComponent("\(videoId).json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let payload = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            return nil
        }
        guard payload.version == 1 || payload.version == currentVersion else { return nil }
        return Entry(
            result: CaptionExtractionResult(
                cues: payload.cues,
                durationSec: payload.version == 1 ? nil : payload.durationSec
            ),
            needsMetadataRefresh: payload.version == 1
        )
    }

    func set(_ videoId: String, result: CaptionExtractionResult) {
        lock.lock()
        defer { lock.unlock() }
        do {
            // Concurrent legacy refreshes may finish out of order. Once one
            // response has supplied an authoritative positive duration, a
            // later successful response that omitted metadata must not erase
            // it and permanently block managed analysis for this video.
            let preservedDuration = result.durationSec
                ?? load(videoId)?.result.durationSec
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let payload = CacheFile(
                version: currentVersion,
                videoId: videoId,
                cachedAt: Date().timeIntervalSince1970,
                cues: result.cues,
                durationSec: preservedDuration
            )
            let data = try JSONEncoder().encode(payload)
            let path = directory.appendingPathComponent("\(videoId).json")
            try data.write(to: path, options: .atomic)
        } catch {
            // Best-effort: a failed cache write must never disrupt the
            // user's extraction flow. The next extract() will hit the
            // network again — annoying but recoverable.
        }
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
    }

    private struct CacheFile: Codable {
        let version: Int
        let videoId: String
        let cachedAt: Double
        let cues: [Cue]
        let durationSec: Int?
    }
}
