import SwiftUI

struct MeView: View {
    @EnvironmentObject var appState: AppState

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "v\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.whatsubBg.ignoresSafeArea()
                List {
                    Section("账号") {
                        LabeledContent("邮箱", value: appState.session?.email ?? "—")
                            .foregroundStyle(.whatsubInk)
                        licenseRow
                    }
                    .listRowBackground(Color.whatsubBgElev)

                    if appState.currentUser?.hasActiveLicense == false {
                        Section {
                            Link(destination: URL(string: "https://whatsub.eversay.cc/#pricing")!) {
                                Label("去网站购买授权", systemImage: "cart")
                                    .foregroundStyle(.whatsubAccent)
                            }
                        } footer: {
                            Text("购买后用同一邮箱登录即可解锁公共语料库 + 云端 library。")
                        }
                        .listRowBackground(Color.whatsubBgElev)
                    }

                    Section("关于") {
                        LabeledContent("版本", value: versionString)
                            .foregroundStyle(.whatsubInk)
                        Link("官网 whatsub.eversay.cc", destination: URL(string: "https://whatsub.eversay.cc")!)
                            .foregroundStyle(.whatsubAccent)
                    }
                    .listRowBackground(Color.whatsubBgElev)

                    Section("工具") {
                        NavigationLink(destination: ImportView()) {
                            Label("导入视频", systemImage: "arrow.down.circle")
                                .foregroundStyle(.whatsubInk)
                        }
                        NavigationLink(destination: LlmSettingsView()) {
                            Label("LLM 设置", systemImage: "cpu")
                                .foregroundStyle(.whatsubInk)
                        }
                        NavigationLink(destination: ImportQueueView()) {
                            Label("导入队列", systemImage: "tray.and.arrow.down")
                                .foregroundStyle(.whatsubInk)
                        }
                    }
                    .listRowBackground(Color.whatsubBgElev)

                    Section {
                        Button(role: .destructive) {
                            appState.logout()
                        } label: {
                            Text("退出登录").frame(maxWidth: .infinity)
                        }
                    }
                    .listRowBackground(Color.whatsubBgElev)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("我的")
            .task { await appState.refreshMe() }
        }
    }

    @ViewBuilder
    private var licenseRow: some View {
        HStack {
            Text("授权状态").foregroundStyle(.whatsubInk)
            Spacer()
            switch appState.currentUser?.hasActiveLicense {
            case .some(true):
                Label("有效", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            case .some(false):
                Label("未购买", systemImage: "xmark.seal")
                    .foregroundStyle(.whatsubInkMuted)
            case .none:
                Text("查询中…").foregroundStyle(.whatsubInkFaint)
            }
        }
    }
}
