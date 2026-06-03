import SwiftUI
import AVKit
import AVFoundation

/// Routes a `CorpusSource` to the right video player:
///
///   kind == "library"
///     ├─ libraryEntryId resolves (`/library/entry/:id` returns 200 with
///     │   videoUrl)        → AVPlayer (OSS CDN, fast, no VPN)
///     └─ entry missing or videoUrl nil
///         ├─ source.youtubeId present  → YouTubeEmbedView (fallback)
///         └─ no fallback                → placeholder ("视频已删除…")
///
///   kind == "youtube"      → YouTubeEmbedView directly
///   kind == anything else  → placeholder
///
/// Why this exists (2026-06-03): builds ≤ 246 stamped EVERY corpus phrase
/// with `kind: "youtube"`, even ones collected from a self-hosted Library
/// video. They played via YT embed → required VPN + heavyweight WKWebView →
/// silly given the same content sits on OSS CDN. Stage 1 of the corpus
/// refactor now records `kind: "library"` + libraryEntryId for those
/// collections; this view picks the right player at display time.
///
/// Use:
///   PhrasePlayerView(source: c.source)
///       .aspectRatio(16.0/9.0, contentMode: .fit)
struct PhrasePlayerView: View {
    let source: CorpusSource
    /// Caller-controlled seek. Pass nil to use `source.timestampSec` as the
    /// initial start point (default behaviour). Set to a value to jump the
    /// player to that second — used by the grouped corpus view to seek the
    /// shared player when the user taps a phrase row.
    var seekTo: Double? = nil

    @EnvironmentObject private var appState: AppState
    @State private var resolution: Resolution = .loading
    @State private var avPlayer: AVPlayer? = nil
    /// Last `seekTo` value we honored — so re-renders with the same seek
    /// don't keep triggering AVPlayer.seek() on every body recompute.
    @State private var lastAppliedSeek: Double? = nil

    enum Resolution: Equatable {
        case loading
        case oss
        case youtube(String)
        case unavailable(String)
    }

    var body: some View {
        Group {
            switch resolution {
            case .loading:
                ZStack {
                    Color.black
                    ProgressView().tint(.white)
                }
            case .oss:
                if let avPlayer {
                    VideoPlayerView(
                        player: avPlayer,
                        seek: nil,
                        currentCue: nil,
                        showCaptions: false,
                        onReady: {},
                        onTime: { _ in }
                    )
                } else {
                    placeholder(reason: "播放器初始化失败")
                }
            case .youtube(let id):
                YouTubeEmbedView(
                    videoId: id,
                    seek: nil,
                    onReady: {},
                    onTime: { _ in },
                    startSeconds: source.timestampSec
                )
            case .unavailable(let reason):
                placeholder(reason: reason)
            }
        }
        .task(id: source.libraryEntryId ?? source.youtubeId ?? source.url ?? "") {
            await resolve()
        }
        .onChange(of: seekTo) { newValue in
            applySeekIfNeeded(newValue)
        }
    }

    private func placeholder(reason: String) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "video.slash")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.5))
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
    }

    @MainActor
    private func resolve() async {
        switch source.kind {
        case "library":
            // Need a library entry id + a session token to call the backend.
            guard let entryId = source.libraryEntryId, !entryId.isEmpty else {
                fallbackOrUnavailable()
                return
            }
            guard let token = appState.session?.sessionToken else {
                fallbackOrUnavailable()
                return
            }
            do {
                let detail = try await WhatsubAPI.shared.libraryEntry(id: entryId, token: token)
                if let videoUrlStr = detail.videoUrl,
                   let url = URL(string: videoUrlStr) {
                    let p = AVPlayer(url: url)
                    if let t = source.timestampSec {
                        await p.seek(to: CMTime(seconds: t, preferredTimescale: 600))
                    }
                    p.automaticallyWaitsToMinimizeStalling = true
                    self.avPlayer = p
                    self.resolution = .oss
                    self.lastAppliedSeek = source.timestampSec
                    return
                }
                // Entry exists but no OSS videoUrl (older entries pre-OSS).
                fallbackOrUnavailable()
            } catch {
                // Entry deleted (404) / network failure — fall back.
                fallbackOrUnavailable()
            }

        case "youtube":
            // Prefer explicit youtubeId, fall back to extracting from url.
            if let id = source.youtubeId, !id.isEmpty {
                self.resolution = .youtube(id)
            } else if let url = source.url,
                      let id = extractYouTubeID(url) {
                self.resolution = .youtube(id)
            } else {
                self.resolution = .unavailable("找不到 YouTube id")
            }

        case "webpage", "pdf", "manual":
            self.resolution = .unavailable("非视频来源")

        default:
            self.resolution = .unavailable("无法识别的来源类型：\(source.kind)")
        }
    }

    /// "Try YT fallback, else unavailable" — used by both the library-404
    /// path and the no-videoUrl path.
    private func fallbackOrUnavailable() {
        if let id = source.youtubeId, !id.isEmpty {
            self.resolution = .youtube(id)
        } else {
            self.resolution = .unavailable("视频已删除")
        }
    }

    /// Called when seekTo binding changes (Stage 4: tap-to-seek inside a
    /// grouped video card). Only applies to the OSS path because YT
    /// player's seek surface uses a different API.
    private func applySeekIfNeeded(_ target: Double?) {
        guard let target, target != lastAppliedSeek else { return }
        if case .oss = resolution, let avPlayer {
            Task {
                await avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                avPlayer.play()
                await MainActor.run { lastAppliedSeek = target }
            }
        }
    }
}
