import SwiftUI

/// AsyncImage replacement that solves two iOS-specific failure modes
/// `SwiftUI.AsyncImage` doesn't handle:
///
///   1. **AsyncImage caches by URL identity and never retries.** Once a
///      request fails (403, timeout, network error), AsyncImage stays in
///      its `.failure` phase forever — even if the user pulls to
///      refresh, the URL didn't change so the view doesn't re-fetch.
///      Real-world repro: user opens a VPN, the request to our
///      Beijing-hosted thumb endpoint gets routed through HK egress, the
///      backend (or an upstream filter) returns 4xx or times out. User
///      closes VPN, pulls to refresh — thumbnails still gone because
///      AsyncImage doesn't know to try again.
///
///   2. **URLCache may serve back the failed response.** Even if we
///      could nudge AsyncImage to re-fetch, the failed response can be
///      sitting in `URLCache.shared` and get returned without hitting
///      the network. We force `.reloadIgnoringLocalAndRemoteCacheData`
///      to skip the cache on every request.
///
/// External refresh: pass any `Hashable` `refreshId` and bump it (from
/// the parent's `.refreshable {}` or pull-to-refresh handler) to force
/// a fresh fetch. The view's `.task(id:)` is keyed on `(url, refreshId)`
/// so changing either re-triggers `load()`.
///
/// User-facing retry: tapping the placeholder also re-fetches via an
/// internal counter. Cheap escape hatch for cases where the parent
/// hasn't wired pull-to-refresh.
///
/// One-shot internal retry on network errors: failed `URLError`s (not
/// HTTP 4xx — those are deterministic) get a single 1.2s-backoff retry.
/// This catches the common case where the user's VPN just dropped and
/// the first request hit the dying connection but the next one rides
/// the new path cleanly.
struct RemoteImage<RefreshID: Hashable>: View {
    let url: URL?
    let refreshId: RefreshID

    @State private var image: UIImage?
    @State private var failed = false
    @State private var manualRetry = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                // Tap-to-retry placeholder. Color/icon match the
                // existing AsyncImage placeholders so callers can keep
                // their visual style — they pass the placeholder via
                // an overlay if they want a custom one.
                ZStack {
                    Color.whatsubBgSoft
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                        .foregroundStyle(.whatsubInkFaint)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    failed = false
                    manualRetry += 1
                }
            } else {
                // Loading state — same neutral background as failed,
                // but no icon, so the row doesn't shift when load
                // finishes.
                Color.whatsubBgSoft
            }
        }
        .task(id: TaskKey(url: url?.absoluteString, refreshId: refreshId, manualRetry: manualRetry)) {
            await load()
        }
    }

    /// Compound task ID: changes when URL changes, when parent bumps
    /// `refreshId` (pull-to-refresh), OR when the user taps the
    /// placeholder. `Hashable` synthesized so SwiftUI's `.task(id:)`
    /// equality check fires on any of these axes.
    private struct TaskKey: Hashable {
        let url: String?
        let refreshId: RefreshID
        let manualRetry: Int
    }

    private func load() async {
        // Reset visible state on a new task. If a previous attempt
        // succeeded but URL changed, we want the old image to clear so
        // the user sees the loading state rather than a stale cover.
        image = nil
        failed = false

        guard let url else { return }

        do {
            let img = try await fetch(url: url)
            image = img
        } catch {
            // One-shot retry for transient errors (URLError = network
            // layer). HTTP-level rejections (4xx wrapped as our own
            // throw) don't get retried — they'd just fail again.
            if error is URLError {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                do {
                    let img = try await fetch(url: url)
                    image = img
                    return
                } catch {
                    // fall through
                }
            }
            failed = true
        }
    }

    private func fetch(url: URL) async throws -> UIImage {
        var req = URLRequest(url: url)
        // Skip both local (memory/disk URLCache) and any intermediary
        // caches. We accept the bandwidth cost — thumbs are tiny
        // (~15-20KB) and the cache-poisoning risk dominates here.
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        guard let img = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return img
    }
}
