import SwiftUI

struct ImportView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: StoreManager
    @StateObject private var vm = ImportViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var urlInput = ""
    @State private var didAutoRun = false
    /// Diagnostics sheet for the .extractFailed phase. Surfaces the
    /// extractor's per-step event log so the user can self-triage instead of
    /// guessing why captions weren't found.
    @State private var showDiagnostics = false
    @State private var diagnosticsLog: [String] = []
    @State private var showVPNHelp = false

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
            case .analyzing(let done, let total, let cueCount):
                progressBody(
                    icon: "sparkles",
                    label: "AI 解析中 \(done)/\(total)\n\(Self.eta(forCues: cueCount))",
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
            case .pushedToDesktop(let desktopOffline):
                pushedToDesktopBody(desktopOffline: desktopOffline)
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
            // Order mirrors the buttons below (手机解析 first).
            VStack(spacing: 4) {
                Text("**「手机解析」仅支持 YouTube 链接**")
                    .font(.caption)
                    .foregroundStyle(.whatsubInkMuted)
                Text("**「推送到桌面」需保持电脑端 whatSub 开启**")
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

            // 「手机解析」 is the PRIMARY action (top slot, solid accent) as
            // of 2026-07-05 — it needs no desktop and finishes in ~1min, but
            // when it sat below the desktop button most users never picked
            // it. Still always visible but greyed for non-YouTube URLs
            // (user feedback 2026-06-06: hiding it read as a missing
            // feature rather than a gated one).
            VStack(spacing: 4) {
                Button(action: startImport) {
                    Label("手机解析（推荐 · 无需电脑）", systemImage: "iphone")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background((isEmpty || !isYouTube)
                                    ? Color.whatsubAccent.opacity(0.4)
                                    : Color.whatsubAccent)
                        .foregroundStyle(.black)
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

            // 「推送到桌面端」 secondary (outline). Its OSS-hosted result
            // plays without VPN — worth keeping discoverable, but it needs
            // the desktop app running, which trips users who don't have it.
            Button(action: startPush) {
                Label("推送到桌面端（免 VPN 流畅观看）", systemImage: "desktopcomputer.and.arrow.down")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isEmpty ? Color.whatsubInkFaint : Color.whatsubAccent,
                                    lineWidth: 1.5)
                    )
                    .foregroundStyle(isEmpty ? Color.whatsubInkFaint : Color.whatsubAccent)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            .disabled(isEmpty)

            Spacer()
        }
        .padding()
    }

    // MARK: - Progress

    private func progressBody(icon: String, label: String, progress: Double?) -> some View {
        VStack(spacing: 24) {
            Spacer()
            // Pulsing icon — without animation here the screen looked frozen
            // during long LLM calls (the linear bar sat at 0/1 for ~10 s
            // before the first chunk landed). Two cues are now alive:
            // (a) the icon pulses, (b) the indeterminate spinner under the
            // bar — so users see *something* is happening even when
            // determinate progress hasn't ticked.
            PulsingIcon(systemName: icon)

            Text(label)
                .font(.headline)
                .foregroundStyle(.whatsubInk)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                if let progress, progress > 0 {
                    ProgressView(value: progress)
                        .tint(.whatsubAccent)
                        .padding(.horizontal, 40)
                }
                // Always show an indeterminate spinner: when the
                // determinate value is stuck at 0 (mid-LLM-request) the
                // spinner is the only sign the network call is live.
                ProgressView()
                    .tint(.whatsubAccent)
            }

            Spacer()
        }
        .padding()
    }

    /// Brand sparkle / icon that pulses opacity+scale so progress-screen
    /// dwell time doesn't feel frozen.
    private struct PulsingIcon: View {
        let systemName: String
        @State private var pulsing = false
        var body: some View {
            Image(systemName: systemName)
                .font(.system(size: 44))
                .foregroundStyle(.whatsubAccent)
                .scaleEffect(pulsing ? 1.12 : 0.92)
                .opacity(pulsing ? 1.0 : 0.55)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                           value: pulsing)
                .onAppear { pulsing = true }
        }
    }

    // MARK: - Captions Ready (NEW — between extract and AI analysis)

    // MARK: - Preview

    /// Vestigial — the new auto-sync flow transitions from .analyzing
    /// straight to .syncing, so .preview is never set in normal use.
    /// Kept as a safety net (renders the annotated cues with no sync
    /// button — sync already triggers automatically on analyze success
    /// upstream in `performAnalysis`). Removed the「同步到云库」button
    /// per user feedback 2026-06-21: "解析完之后…我觉得不要这个了直接就同步".
    private var previewBody: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if let subtitles = vm.result?.subtitles {
                    ForEach(subtitles) { cue in
                        CueRow(
                            cue: cue,
                            isCurrent: false,
                            onTapCue: {},
                            onTapHighlight: { _, _, _, _ in },
                            onCollect: {}
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 24)
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
                .textSelection(.enabled)
            // Smart retry: if rawCues is in memory (extraction succeeded,
            // AI stage failed) — retry the AI step directly with the same
            // cues. Otherwise reset to idle so URL input shows.
            if !vm.rawCues.isEmpty {
                Button("重试 AI 解析") {
                    guard let token = appState.session?.sessionToken else { return }
                    Task { await vm.retryAnalysisOnly(token: token) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.whatsubAccent)
            } else {
                Button("重试") {
                    vm.state = .idle
                }
                .buttonStyle(.bordered)
                .tint(.whatsubAccent)
            }
            // VPN 规则 tutorial — only useful when the user is on the relay
            // (BYOK users hit their own LLM vendor directly, no eversay.cc
            // detour). Showing it indiscriminately would confuse BYOK users
            // wondering why we're suggesting VPN tweaks.
            if LlmSettingsStore.load().useManagedRelay {
                Button {
                    showVPNHelp = true
                } label: {
                    Label("查看 VPN 设置方法（切到规则模式即可）", systemImage: "network.badge.shield.half.filled")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
                .tint(.whatsubAccent)
            }
            Spacer()
        }
        .sheet(isPresented: $showVPNHelp) { VPNRuleHelpSheet() }
    }

    // MARK: - Extracting (spinner only)

    /// During native Innertube extraction (spec §7.1) there's nothing
    /// visual to show — the network calls return in 1-3 seconds, often
    /// faster than the user notices. A centred spinner + status line is
    /// honest and avoids the previous WebView-mount-during-warmup UX
    /// noise where users saw an unrelated YouTube homepage preview.
    private var extractingBody: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .tint(.whatsubAccent)
                .scaleEffect(1.2)
            Text("字幕提取中…")
                .font(.headline)
                .foregroundStyle(.whatsubInk)
            Text("通常 1-3 秒")
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
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

    private func pushedToDesktopBody(desktopOffline: Bool) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("已推送到桌面端")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.whatsubInk)

            if desktopOffline {
                // The backend hasn't seen this account's desktop client
                // recently — without this callout the task queues silently
                // forever and the user never learns why nothing happened.
                VStack(spacing: 8) {
                    Label("你的桌面端似乎不在线", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.yellow)
                    Text("任务已排队，但只有打开电脑上的 whatSub 并登录同一账号（\(appState.session?.email ?? "当前账号")）后才会开始下载和解析。")
                        .font(.subheadline)
                        .foregroundStyle(.whatsubInk)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.5), lineWidth: 1))
                .padding(.horizontal)
            } else {
                Text("检测到桌面端在线，马上会自动开始下载+解析。可在「我的 → 导入队列」查看进度。")
                    .font(.subheadline)
                    .foregroundStyle(.whatsubInkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

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
                Task { await vm.pushToDesktop(token: token, email: appState.session?.email) }
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
        guard let token = appState.session?.sessionToken else {
            vm.state = .error("请先登录")
            return
        }
        // run() now auto-flows extract → analyze → sync → done; needs the
        // token + email up front so it can chain into sync without
        // bouncing through a manual "同步到云库" confirmation.
        Task { await vm.run(urlOrId: urlInput, token: token, email: appState.session?.email) }
    }

    /// Coarse time estimate for the streaming analyze stage. ~1s per cue
    /// on deepseek-v4-flash + ~5s phase-2 summary. Floor at 30s so a
    /// 5-cue short doesn't look like "约 10 秒" then take 25s anyway.
    static func eta(forCues count: Int) -> String {
        let est = max(30, count + 5)
        if est < 60 { return "预计约 \(est) 秒" }
        let m = est / 60
        let s = est % 60
        if s < 15 { return "预计约 \(m) 分钟" }
        return "预计约 \(m) 分 \(s) 秒"
    }

    private func startPush() {
        guard let token = appState.session?.sessionToken else {
            vm.state = .error("请先登录")
            return
        }
        Task { await vm.pushURL(urlInput, token: token, email: appState.session?.email) }
    }

    private func pushToDesktop() {
        guard let token = appState.session?.sessionToken else {
            vm.state = .error("请先登录")
            return
        }
        Task { await vm.pushToDesktop(token: token, email: appState.session?.email) }
    }
}
