import SwiftUI

struct ImportView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: StoreManager
    @StateObject private var vm = ImportViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var urlInput = ""
    @State private var didAutoRun = false
    /// Diagnostics sheet for the .extractFailed phase. Surfaces the rich
    /// CaptionExtractor event log so the user can self-triage instead of
    /// guessing why captions weren't found.
    @State private var showDiagnostics = false
    @State private var diagnosticsLog: [String] = []

    private let initialURL: String?

    /// Default initialiser — used by the 我的 → 导入 entry point.
    init() {
        self.initialURL = nil
    }

    /// Deep-link initialiser — prefills the URL field and auto-runs on appear.
    init(initialURL: String) {
        self.initialURL = initialURL
    }

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()

            switch vm.state {
            case .idle:
                idleBody
            case .extracting:
                extractingBody
            case .analyzing(let done, let total):
                progressBody(
                    icon: "sparkles",
                    label: "AI 解析中 \(done)/\(total)",
                    progress: total > 0 ? Double(done) / Double(total) : nil
                )
            case .preview:
                previewBody
            case .syncing:
                progressBody(icon: "arrow.up.circle", label: "同步到云库…", progress: nil)
            case .done:
                doneBody
            case .error(let msg):
                errorBody(msg)
            case .extractFailed(let msg, let debug):
                pushOfferBody(title: "未找到字幕", message: msg, debug: debug)
            case .needsDesktop(let msg):
                pushOfferBody(title: "需在桌面端处理", message: msg)
            case .pushing:
                progressBody(icon: "desktopcomputer.and.arrow.down", label: "推送到桌面端…", progress: nil)
            case .pushedToDesktop:
                pushedToDesktopBody
            case .quotaWall(let used, let limit):
                quotaWallBody(used: used, limit: limit)
            }
        }
        .navigationTitle("导入视频")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didAutoRun, let url = initialURL else { return }
            didAutoRun = true
            urlInput = url
            // No auto-run: the user chooses 手机解析 vs 推送桌面 on the idle screen.
        }
    }

    // MARK: - Idle

    private var idleBody: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.whatsubAccent)

            Text("粘贴 YouTube / B站 / 其它视频链接")
                .font(.headline)
                .foregroundStyle(.whatsubInk)

            // Concise two-line summary — was a paragraph with parens that
            // users found too dense (2026-06-07 feedback). Bold the
            // requirements that block the path so they're scannable.
            VStack(spacing: 4) {
                Text("**「推送到桌面」需保持电脑端 whatSub 开启**")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
                Text("**「手机解析」仅支持 YouTube 链接**")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
            }
            .multilineTextAlignment(.center)

            TextField("https://… 或 YouTube 11 位 ID", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal)

            let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let isEmpty = trimmed.isEmpty
            let isYouTube = VideoSource.from(url: trimmed) == .youtube || VideoSource.isLikelyYouTubeId(trimmed)

            Button(action: startPush) {
                Label("推送到桌面端（免 VPN 流畅观看）", systemImage: "desktopcomputer.and.arrow.down")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isEmpty ? Color.whatsubAccent.opacity(0.4) : Color.whatsubAccent)
                    .foregroundStyle(.black)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            .disabled(isEmpty)

            // 「手机解析」 always visible but disabled when the URL isn't
            // YouTube. Was conditionally rendered (only shown for YT URLs)
            // — user feedback 2026-06-06: "弹出页面只有推送到桌面端,没有
            // 手机端解析按钮了". Hiding it confused users: they thought it
            // was a missing feature rather than a gated one. Now both
            // surfaces are always visible; non-YT URLs see the button
            // greyed with a one-line explanation.
            VStack(spacing: 4) {
                Button(action: startImport) {
                    Label("手机解析（看时需挂 VPN）", systemImage: "iphone")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isYouTube ? Color.whatsubAccent : Color.whatsubInkFaint,
                                        lineWidth: 1.5)
                        )
                        .foregroundStyle(isYouTube ? Color.whatsubAccent : Color.whatsubInkFaint)
                        .cornerRadius(12)
                }
                .disabled(isEmpty || !isYouTube)

                if !isEmpty && !isYouTube {
                    Text("仅支持 YouTube 链接 (B 站/其它请用「推送到桌面端」)")
                        .font(.caption2)
                        .foregroundStyle(.whatsubInkMuted)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
    }

    // MARK: - Progress

    private func progressBody(icon: String, label: String, progress: Double?) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.whatsubAccent)

            Text(label)
                .font(.headline)
                .foregroundStyle(.whatsubInk)
                .multilineTextAlignment(.center)

            if let progress {
                ProgressView(value: progress)
                    .tint(.whatsubAccent)
                    .padding(.horizontal, 40)
            } else {
                ProgressView()
                    .tint(.whatsubAccent)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Preview

    private var previewBody: some View {
        VStack(spacing: 0) {
            if let subtitles = vm.result?.subtitles {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(subtitles) { cue in
                            CueRow(
                                cue: cue,
                                isCurrent: false,
                                onTapCue: {},
                                onTapHighlight: { _, _, _, _ in },  // import preview: no gloss sheet
                                onCollect: {}                    // import preview: no notebook yet
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 100)
                }
            }

            // Floating sync button at the bottom.
            VStack(spacing: 0) {
                Divider().background(Color.white.opacity(0.08))
                Button(action: startSync) {
                    Text("同步到云库")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.whatsubAccent)
                        .foregroundStyle(.black)
                        .cornerRadius(12)
                }
                .padding()
                .background(Color.whatsubBg)
            }
        }
    }

    // MARK: - Done

    private var doneBody: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("已同步到云库")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.whatsubInk)
            Text("可在 Library 标签页中查看")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
            Button("完成") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.whatsubAccent)
                .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Error

    private func errorBody(_ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.whatsubHighlight)
            Text("出错了")
                .font(.headline)
                .foregroundStyle(.whatsubInk)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("重试") {
                vm.state = .idle
            }
            .buttonStyle(.bordered)
            .tint(.whatsubAccent)
            Spacer()
        }
    }

    // MARK: - Extracting (visible YT player + status)

    /// During extraction we show the WKWebView at full opacity. Three
    /// benefits over the previous opacity-0.001 invisible mount:
    ///   1. User can see YouTube actually loading + playing, which makes
    ///      the 15-25s wait less mysterious ("did it freeze?" → no,
    ///      look, the video's literally on screen).
    ///   2. YouTube's IntersectionObserver / visibilityState checks see
    ///      a fully-visible player → no chance of caption-track
    ///      suspension on visibility grounds (previously a guess).
    ///   3. The hook's `setInterval` mute keeps audio silent so it's
    ///      not a UX nuisance. allowsHitTesting(false) prevents the user
    ///      accidentally tapping pause / scrub mid-extraction.
    private var extractingBody: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .tint(.whatsubAccent)
                .scaleEffect(1.2)

            Text("字幕提取中…")
                .font(.headline)
                .foregroundStyle(.whatsubInk)

            if let web = vm.liveWebView {
                // Mount the WebView in the view tree (required so YouTube's
                // IntersectionObserver sees it as visible) but keep it
                // hidden during warmup — otherwise the user sees the YT
                // homepage's auto-playing preview banner for ~3.5s, which
                // looks like "this is showing me a random unrelated video"
                // (user-reported 2026-06-18). opacity 0.001 still gives
                // IntersectionObserver enough; flips to 1.0 once
                // CaptionExtractor's onWatchNavigation fires.
                WKWebViewHost(webView: web)
                    .frame(width: 320, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        // Matches the website brand token `--hairline-strong`
                        // (rgba(255,255,255,0.14)). Theme.swift doesn't ship a
                        // named static for it, so inline the literal here.
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .opacity(vm.liveWebViewWatching ? 1.0 : 0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 4) {
                Text("YouTube 播放器正在加载视频字幕轨")
                    .font(.subheadline)
                    .foregroundStyle(.whatsubInkMuted)
                Text("需挂 VPN · 不要锁屏 · 大概 15-25 秒")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkFaint)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            Spacer()
        }
        .padding()
    }

    // MARK: - Extract Failed (offer push to desktop)

    private func pushOfferBody(title: String, message: String, debug: [String] = []) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 48))
                .foregroundStyle(.whatsubHighlight)

            Text(title)
                .font(.headline)
                .foregroundStyle(.whatsubInk)

            // Single explanation paragraph — the CaptionError's
            // localized description already covers everything (likely
            // causes + next-step CTAs). 2026-06-18: a previous version
            // had a second hardcoded "此视频可能没有字幕…" block under
            // a divider that just repeated the same info; user pointed
            // it out, removed.
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: pushToDesktop) {
                Label("推送到桌面端处理", systemImage: "desktopcomputer.and.arrow.down")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.whatsubAccent)
                    .foregroundStyle(.black)
                    .cornerRadius(12)
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button("重试") {
                    vm.state = .idle
                }
                .buttonStyle(.bordered)
                .tint(.whatsubAccent)

                // Only show 查看诊断 if we actually have a log to surface —
                // the desktop-needed path (`.needsDesktop`) calls this view
                // with empty debug; no point showing a button into nothing.
                if !debug.isEmpty {
                    Button {
                        diagnosticsLog = debug
                        showDiagnostics = true
                    } label: {
                        Label("查看诊断", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.whatsubInkSoft)
                }
            }

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showDiagnostics) {
            CaptionDiagnosticsSheet(log: diagnosticsLog)
        }
    }

    // MARK: - Pushed to Desktop

    private var pushedToDesktopBody: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("已推送到桌面端")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.whatsubInk)

            Text("已加入桌面处理队列。桌面端在线时会自动下载+解析；若当前不在线，任务会排队，等下次上线自动处理。可在「我的 → 导入队列」查看进度。")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("完成") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.whatsubAccent)
                .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Quota wall (over cloud-video cap)

    private func quotaWallBody(used: Int, limit: Int) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "icloud.slash")
                .font(.system(size: 48))
                .foregroundStyle(.whatsubHighlight)
            Text("云端视频已达上限")
                .font(.headline)
                .foregroundStyle(.whatsubInk)
            Text("已用 \(used)/\(limit) 个云端视频。")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)

            // 2026-05-28 policy shift: all users (license or not) can subscribe
            // directly via Apple IAP. The old non-license branch ("在官网用同一
            // 邮箱购买授权后再订阅") was stale gating from the buyout era — Pro is
            // now a single subscription path everywhere, no license prerequisite.
            Text("订阅 Pro 解锁 50 个云端额度，单个视频提升到 500MB / 60 分钟；订阅成功会自动继续这次推送。")
                .font(.subheadline)
                .foregroundStyle(.whatsubInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            SubscriptionOptionsView(onPurchased: {
                guard let token = appState.session?.sessionToken else { return }
                Task { await vm.pushToDesktop(token: token) }
            })
            .padding(.horizontal)

            Button("完成") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.whatsubAccent)
                .padding(.top, 4)
            Spacer()
        }
        .padding()
    }

    // MARK: - Actions

    private func startImport() {
        Task { await vm.run(urlOrId: urlInput) }
    }

    private func startPush() {
        guard let token = appState.session?.sessionToken else {
            vm.state = .error("请先登录")
            return
        }
        Task { await vm.pushURL(urlInput, token: token) }
    }

    private func startSync() {
        guard let token = appState.session?.sessionToken else {
            vm.state = .error("请先登录")
            return
        }
        Task { await vm.sync(token: token) }
    }

    private func pushToDesktop() {
        guard let token = appState.session?.sessionToken else {
            vm.state = .error("请先登录")
            return
        }
        Task { await vm.pushToDesktop(token: token) }
    }
}
