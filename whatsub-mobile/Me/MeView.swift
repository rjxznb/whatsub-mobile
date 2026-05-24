import SwiftUI
import StoreKit

struct MeView: View {
    @EnvironmentObject var appState: AppState
    @State private var quota: LibraryQuota?
    @EnvironmentObject var store: StoreManager
    @State private var showManageSubscriptions = false

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "v\(v) (\(b))"
    }

    private var subPlanName: String {
        // `subProductId` is String?; plain == avoids switch-on-optional pattern subtleties.
        let pid = appState.currentUser?.subProductId
        if pid == StoreManager.subMonthID { return "包月" }
        if pid == StoreManager.subYearID { return "包年" }
        return "已订阅"
    }

    private func reloadQuota() async {
        await appState.refreshMe()
        if let t = appState.session?.sessionToken {
            quota = try? await WhatsubAPI.shared.libraryQuota(token: t)
        }
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

                    Section("云端同步") {
                        if let q = quota {
                            LabeledContent("云端视频", value: "\(q.used)/\(q.limit)")
                                .foregroundStyle(.whatsubInk)
                        }
                        if appState.currentUser?.hasActiveLicense == true {
                            if appState.currentUser?.iosSubActive == true {
                                Label("已订阅 · \(subPlanName)", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(.whatsubAccent)
                                Button("管理订阅") { showManageSubscriptions = true }
                                    .foregroundStyle(.whatsubAccent)
                            } else {
                                Text("订阅解锁 50 个云端视频额度。")
                                    .font(.footnote).foregroundStyle(.whatsubInkMuted)
                                SubscriptionOptionsView(onPurchased: { Task { await reloadQuota() } })
                                    .padding(.vertical, 4)
                            }
                        } else {
                            Text("免费 3 个云端视频。开通网站授权后可订阅解锁 50 个；需要手机端公共语料库也请在官网用同一邮箱开通授权后回到这里登录。")
                                .font(.footnote).foregroundStyle(.whatsubInkMuted)
                        }
                    }
                    .listRowBackground(Color.whatsubBgElev)
                    .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)

                    if appState.currentUser?.hasActiveLicense == false {
                        Section {
                            // Plain text, no tappable purchase link (App Store anti-steering).
                            Label("购买授权请前往官网", systemImage: "cart")
                                .foregroundStyle(.whatsubInkMuted)
                        } footer: {
                            Text("在官网用同一邮箱开通授权后，回到这里登录即可解锁公共语料库 + 云端 library。")
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
            .task { await reloadQuota() }
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
