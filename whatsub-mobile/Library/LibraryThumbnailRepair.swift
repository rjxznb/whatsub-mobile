import Foundation
import UIKit

struct YouTubeThumbnailFetcher {
    typealias Fetch = (URL) async throws -> Data
    typealias Sleep = (UInt64) async -> Void

    @MainActor static let shared = YouTubeThumbnailFetcher()

    private let fetch: Fetch
    private let sleep: Sleep

    init(
        fetch: @escaping Fetch = { url in
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        },
        sleep: @escaping Sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.fetch = fetch
        self.sleep = sleep
    }

    func fetchBase64(videoID: String) async -> String? {
        guard Self.isYouTubeVideoID(videoID) else { return nil }
        let urls = [
            URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")!,
            URL(string: "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg")!,
        ]
        for round in 0..<2 {
            for url in urls {
                guard !Task.isCancelled else { return nil }
                do {
                    let data = try await fetch(url)
                    guard let image = UIImage(data: data),
                          let jpeg = image.jpegData(compressionQuality: 0.86),
                          !jpeg.isEmpty,
                          jpeg.count <= 1024 * 1024 else { continue }
                    return jpeg.base64EncodedString()
                } catch {
                    continue
                }
            }
            if round == 0 {
                await sleep(800_000_000)
            }
        }
        return nil
    }

    static func isYouTubeVideoID(_ value: String) -> Bool {
        value.count == 11 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }
}

final class ThumbnailRepairCooldownStore {
    private let defaults: UserDefaults
    private let cooldown: TimeInterval
    private let keyPrefix = "library.thumbnailRepair.lastFailure."

    init(defaults: UserDefaults = .standard, cooldown: TimeInterval = 6 * 3600) {
        self.defaults = defaults
        self.cooldown = cooldown
    }

    func shouldAttempt(entryID: String, at now: Date) -> Bool {
        guard let failedAt = defaults.object(forKey: keyPrefix + entryID) as? Date else { return true }
        return now.timeIntervalSince(failedAt) >= cooldown
    }

    func recordFailure(entryID: String, at now: Date) {
        defaults.set(now, forKey: keyPrefix + entryID)
    }

    func clear(entryID: String) {
        defaults.removeObject(forKey: keyPrefix + entryID)
    }
}

@MainActor
final class LibraryThumbnailRepairService {
    typealias Fetch = (String) async -> String?
    typealias Upload = (String, String, String) async throws -> Void

    private let cooldown: ThumbnailRepairCooldownStore
    private let now: () -> Date
    private let fetch: Fetch
    private let upload: Upload

    init(
        cooldown: ThumbnailRepairCooldownStore = ThumbnailRepairCooldownStore(),
        now: @escaping () -> Date = Date.init,
        fetch: @escaping Fetch = { videoID in
            await YouTubeThumbnailFetcher.shared.fetchBase64(videoID: videoID)
        },
        upload: @escaping Upload = { entryID, thumbData, token in
            try await WhatsubAPI.shared.repairLibraryThumbnail(
                entryID: entryID,
                thumbData: thumbData,
                token: token
            )
        }
    ) {
        self.cooldown = cooldown
        self.now = now
        self.fetch = fetch
        self.upload = upload
    }

    func repair(entries: [LibraryListItem], token: String) async -> Set<String> {
        let attemptTime = now()
        let candidates = entries.lazy.filter {
            $0.thumbUrl == nil
                && YouTubeThumbnailFetcher.isYouTubeVideoID($0.youtubeId)
                && self.cooldown.shouldAttempt(entryID: $0.id, at: attemptTime)
        }.prefix(5)
        var repaired = Set<String>()
        for entry in candidates {
            guard !Task.isCancelled else { break }
            guard let thumbData = await fetch(entry.youtubeId) else {
                if !Task.isCancelled { cooldown.recordFailure(entryID: entry.id, at: now()) }
                continue
            }
            do {
                try await upload(entry.id, thumbData, token)
                cooldown.clear(entryID: entry.id)
                repaired.insert(entry.id)
            } catch is CancellationError {
                break
            } catch {
                cooldown.recordFailure(entryID: entry.id, at: now())
            }
        }
        return repaired
    }
}

extension LibraryListItem {
    func replacingThumbnailURL(_ thumbURL: String) -> LibraryListItem {
        LibraryListItem(
            id: id,
            youtubeId: youtubeId,
            sourceUrl: sourceUrl,
            title: title,
            durationSec: durationSec,
            thumbUrl: thumbURL,
            syncedAt: syncedAt,
            videoUrl: videoUrl,
            audioUrl: audioUrl
        )
    }
}
