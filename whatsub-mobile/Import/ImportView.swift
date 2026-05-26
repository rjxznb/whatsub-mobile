import SwiftUI

struct ImportView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: StoreManager
    @StateObject private var vm = ImportViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var urlInput = ""
    @State private var didAutoRun = false

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
                progressBody(icon: "captions.bubble", label: "提取字幕中…（需挂 VPN）", progress: nil)
            case .analyzing(let done, let total):
                progressBody(
                    icon: "brain",
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
            case .extractFailed(let msg):
                pushOfferBody(title: "未找到字幕", message: msg)
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

            Text("推送到桌面端：桌面下载+转写后，手机免 VPN 流畅观看（需桌面在线，可离线排队）。手机解析：直接在手机抽取字幕，但观看走 YouTube 需挂 VPN。（仅 YouTube 支持手机解析；B站/其它仅支持推送桌面。）")
                .font(.caption)
                .foregroundStyle(.whatsubInkMuted)
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

            if isYouTube {
                Button(action: startImport) {
                    Label("手机解析（看时需挂 VPN）", systemImage: "iphone")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.whatsubAccent, lineWidth: 1.5)
                        )
                        .foregroundStyle(.whatsubAccent)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
                .disabled(isEmpty)
            }

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
                                onTapHighlight: { _, _, _ in },  // import preview: no gloss sheet
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

    // MARK: - Extract Failed (offer push to desktop)

    private func pushOfferBody(title: String, message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 48))
                .foregroundStyle(.whatsubHighlight)

            Text(title)
                .font(.headline)
                .foregroundStyle(.whatsubInk)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.whatsubInkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.horizontal, 24)

            Text("此视频可能没有字幕。可推送到桌面端处理（桌面会下载 + whisper 转录 + 解析，需桌面在线且登录同一账号）。")
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

            Button("重试") {
                vm.state = .idle
            }
            .buttonStyle(.bordered)
            .tint(.whatsubAccent)

            Spacer()
        }
        .padding()
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

            if appState.currentUser?.hasActiveLicense == true {
                Text("订阅解锁 50 个云端额度，订阅成功会自动继续这次推送。")
                    .font(.subheadline)
                    .foregroundStyle(.whatsubInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                SubscriptionOptionsView(onPurchased: {
                    guard let token = appState.session?.sessionToken else { return }
                    Task { await vm.pushToDesktop(token: token) }
                })
                .padding(.horizontal)
            } else {
                Text("先在 Library 删一个，或在官网用同一邮箱购买授权后再订阅。")
                    .font(.subheadline)
                    .foregroundStyle(.whatsubInkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

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
