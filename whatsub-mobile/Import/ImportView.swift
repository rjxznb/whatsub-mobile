import SwiftUI

struct ImportView: View {
    @EnvironmentObject var appState: AppState
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
                extractFailedBody(msg)
            case .pushedToDesktop:
                pushedToDesktopBody
            }
        }
        .navigationTitle("导入视频")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didAutoRun, let url = initialURL else { return }
            didAutoRun = true
            urlInput = url
            await vm.run(urlOrId: url)
        }
    }

    // MARK: - Idle

    private var idleBody: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.whatsubAccent)

            Text("粘贴 YouTube 链接或 Video ID")
                .font(.headline)
                .foregroundStyle(.whatsubInk)

            Text("解析需挂 VPN 连接 YouTube")
                .font(.caption)
                .foregroundStyle(.whatsubInkMuted)

            TextField("https://youtube.com/watch?v=… 或 11 位 ID", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal)

            Button(action: startImport) {
                Text("解析导入")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.whatsubAccent)
                    .foregroundStyle(.black)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty)

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
                                onTapHighlight: { _, _, _ in }
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

    private func extractFailedBody(_ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 48))
                .foregroundStyle(.whatsubHighlight)

            Text("未找到字幕")
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

            Text("桌面端在线时会自动处理，完成后出现在 Library。")
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

    // MARK: - Actions

    private func startImport() {
        Task { await vm.run(urlOrId: urlInput) }
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
