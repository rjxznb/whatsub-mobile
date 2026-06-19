import Foundation

/// Per-video disk cache for YouTube caption extraction results.
///
/// Layout: `<directory>/<videoId>.json` — one file per video. Each file
/// is a small JSON object (`version`, `videoId`, `cachedAt`, `cues`).
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
    private let currentVersion = 1

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

    func get(_ videoId: String) -> [Cue]? {
        let path = directory.appendingPathComponent("\(videoId).json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let payload = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            return nil
        }
        guard payload.version == currentVersion else { return nil }
        return payload.cues
    }

    func set(_ videoId: String, cues: [Cue]) {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let payload = CacheFile(
                version: currentVersion,
                videoId: videoId,
                cachedAt: Date().timeIntervalSince1970,
                cues: cues
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
        try? FileManager.default.removeItem(at: directory)
    }

    private struct CacheFile: Codable {
        let version: Int
        let videoId: String
        let cachedAt: Double
        let cues: [Cue]
    }
}
