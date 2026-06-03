import SwiftUI

/// Wraps a URL for `.sheet(item:)` — avoids conforming Foundation's URL to
/// Identifiable (which Apple may add and would then collide).
private struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct PhraseDetailView: View {
    let phrase: String
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = PhraseDetailViewModel()
    @State private var safariURL: IdentifiedURL?
    @State private var playing: CorpusContribution?

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            if vm.loading {
                ProgressView().tint(.whatsubAccent)
            } else if let err = vm.errorMessage {
                Text(err).foregroundStyle(.whatsubInkMuted).padding()
            } else if let r = vm.result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(r.phrase)
                        if !vm.instances.isEmpty {
                            Text("例句出处").font(.headline).foregroundStyle(.whatsubInk)
                            ForEach(vm.instances) { c in instanceCard(c) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(phrase)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let token = appState.session?.sessionToken else { return }
            await vm.load(phrase: phrase, token: token)
        }
        .sheet(item: $safariURL) { item in SafariView(url: item.url) }
    }

    private func header(_ p: LookupPhrase) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.phraseRaw).font(.system(size: 28, weight: .bold)).foregroundStyle(.whatsubInk)
            if let m = p.meaningZh, !m.isEmpty {
                Text(m).font(.title3).foregroundStyle(.whatsubAccent)
            }
            if let u = p.usageNote, !u.isEmpty {
                Text(u).font(.callout).foregroundStyle(.whatsubInkSoft)
            }
            if !p.tags.isEmpty {
                Text(p.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.whatsubInkFaint)
            }
        }
    }

    @ViewBuilder
    private func instanceCard(_ c: CorpusContribution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.contextSentence).font(.body).foregroundStyle(.whatsubInk)
            if let t = c.source.title, !t.isEmpty {
                Text(t).font(.caption).foregroundStyle(.whatsubInkMuted).lineLimit(1)
            }
            // Source-aware player routing (Stage 2 of the corpus refactor,
            // 2026-06-03). Library kind → OSS AVPlayer with YT-embed fallback;
            // youtube kind → YT embed; webpage/manual → Safari link.
            //
            // Click-to-load: only instantiate the player when the user taps
            // "▶ 播放". WKWebView for YouTube alone is 40-80 MB, and a corpus
            // detail page can list 10+ instances — eager-loading all of them
            // is a memory disaster. (Was also true before this change but
            // worse now since OSS AVPlayer needs a backend round-trip.)
            if c.source.kind == "library" || c.source.kind == "youtube" {
                if playing?.id == c.id {
                    PhrasePlayerView(source: c.source)
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                        .background(Color.black)
                } else {
                    sourceButton(icon: "play.circle.fill",
                                 label: c.source.timestampSec.map { "▶ 在 \(mmss($0)) 播放" } ?? "▶ 播放") {
                        playing = c
                    }
                }
            } else {
                // webpage / pdf / curator → open the source URL in Safari.
                sourceButton(icon: "safari", label: "打开来源") {
                    if let raw = c.source.url, let u = URL(string: raw) {
                        safariURL = IdentifiedURL(url: u)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
    }

    private func sourceButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.whatsubAccent)
        }
    }

    private func mmss(_ sec: Double) -> String {
        let s = Int(sec)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
