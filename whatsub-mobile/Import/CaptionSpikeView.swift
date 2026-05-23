import SwiftUI
import WebKit

struct CaptionSpikeView: View {
    // A known captioned video; the user can edit it in the field.
    @State private var videoId = "ECXAFUmdJkI"
    @State private var status = "待加载"
    @State private var cues: [SpikeCue] = []
    @State private var rawLen = 0
    @State private var reload = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("YouTube videoId", text: $videoId)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("加载") { cues = []; rawLen = 0; status = "加载中…"; reload = UUID() }
            }
            Text("状态：\(status)").font(.footnote).foregroundStyle(.whatsubInkMuted)
            Text("捕获 cue：\(cues.count)  | 原始字节：\(rawLen)").font(.footnote).foregroundStyle(.whatsubInk)

            CaptionCaptureWebView(videoId: videoId, reload: reload) { body in
                rawLen = body.utf8.count
                let parsed = parseTimedtextJson3(Data(body.utf8))
                cues = parsed
                status = parsed.isEmpty ? "捕获到 timedtext 但解析为空（可能非 json3，见原始字节）" : "成功捕获 + 解析 ✅"
            }
            .frame(height: 200)
            .background(Color.black)

            List(cues.prefix(8), id: \.idx) { c in
                VStack(alignment: .leading) {
                    Text(String(format: "%.1f–%.1f", c.time, c.end)).font(.caption2).foregroundStyle(.whatsubInkFaint)
                    Text(c.text).font(.footnote).foregroundStyle(.whatsubInk)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .padding()
        .background(Color.whatsubBg.ignoresSafeArea())
        .navigationTitle("字幕提取 spike")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Loads the YouTube watch page with CC forced on, injects the caption hook in
/// the page (MAIN) world at documentStart, and forwards captured timedtext
/// bodies to `onCaptions`.
private struct CaptionCaptureWebView: UIViewRepresentable {
    let videoId: String
    let reload: UUID
    let onCaptions: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCaptions: onCaptions) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let hook = WKUserScript(source: CaptionHookJS.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        cfg.userContentController.addUserScript(hook)
        cfg.userContentController.add(context.coordinator, contentWorld: .page, name: "whatsubCaptions")
        let web = WKWebView(frame: .zero, configuration: cfg)
        context.coordinator.load(web, videoId: videoId)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastReload != reload {
            context.coordinator.lastReload = reload
            context.coordinator.load(web, videoId: videoId)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onCaptions: (String) -> Void
        var lastReload: UUID?
        init(onCaptions: @escaping (String) -> Void) { self.onCaptions = onCaptions }

        func load(_ web: WKWebView, videoId: String) {
            // Watch page with CC force-on (cc_load_policy=1) + auto-select an
            // English track. The full player fetches /api/timedtext when CC loads;
            // the hook (installed at documentStart) catches it.
            let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)&cc_load_policy=1")!
            web.load(URLRequest(url: url))
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "whatsubCaptions",
                  let dict = message.body as? [String: Any],
                  let body = dict["body"] as? String else { return }
            DispatchQueue.main.async { self.onCaptions(body) }
        }
    }
}
