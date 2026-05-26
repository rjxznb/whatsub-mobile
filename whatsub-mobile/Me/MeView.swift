import SwiftUI
import StoreKit

struct MeView: View {
    @EnvironmentObject var appState: AppState
    @State private var quota: LibraryQuota?
    @State private var corpusQ: CorpusQuota?
    @EnvironmentObject var store: StoreManager
    @State private var showManageSubscriptions = false
    @State private var showLogoutConfirm = false
    @State private var showStaging = false
    @State private var showSubscribe = false
    @ObservedObject private var vocab = VocabStore.shared

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
            corpusQ = try? await WhatsubAPI.shared.corpusQuota(token: t)
        }
    }

    var body: some View {
        NavigationStack {
            // Custom large-title header (not .navigationTitle) — the system large
            // title renders unreliably here with our global nav-bar appearance +
            // tab bar, same as Library. See LibraryView for the rationale.
            VStack(alignment: .leading, spacing: 0) {
                Text("我的")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.whatsubInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 8)
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
                        if let cq = corpusQ {
                            LabeledContent("个人语料库", value: "\(cq.used)/\(cq.limit)")
                                .foregroundStyle(.whatsubInk)
                        }
                        // iOS unlocks via IAP only — no website-purchase steering
                        // (App Store 3.1.1). Subscription is offered to anyone not
                        // already iOS-subscribed; the backend grants 50 to any active
                        // subscription (hasActiveSubscription).
                        if appState.currentUser?.iosSubActive == true {
                            Label("已订阅 · \(subPlanName)", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.whatsubAccent)
                            Button("管理订阅") { showManageSubscriptions = true }
                                .foregroundStyle(.whatsubAccent)
                        } else {
                            Text("订阅 Pro 解锁 50 个云端视频 + 1000 个语料库额度；不订阅可免费同步 3 个。")
                                .font(.footnote).foregroundStyle(.whatsubInkMuted)
                            // A single entry button (not inline price buttons) — tapping
                            // opens the payment card. Less money-grabby.
                            Button {
                                showSubscribe = true
                            } label: {
                                Label("订阅 Pro · 解锁 50 视频 + 1000 语料库", systemImage: "star.circle.fill")
                                    .foregroundStyle(.whatsubAccent)
                            }
                        }
                    }
                    .listRowBackground(Color.whatsubBgElev)
                    .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
                    .sheet(isPresented: $showSubscribe) {
                        SubscribeSheet(onPurchased: { Task { await reloadQuota() } })
                            .environmentObject(store)
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
                        Button {
                            showStaging = true
                        } label: {
                            HStack {
                                Label("词汇暂存区", systemImage: "tray.full")
                                    .foregroundStyle(.whatsubInk)
                                Spacer()
                                let n = vocab.count(for: VocabStore.stagingKey)
                                if n > 0 { Text("\(n)").foregroundStyle(.whatsubInkMuted) }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.whatsubInkFaint)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Color.whatsubBgElev)
                    .sheet(isPresented: $showStaging) {
                        VocabNotebookView(entryId: VocabStore.stagingKey, title: "暂存区", onJump: nil)
                    }

                    Section {
                        Button(role: .destructive) {
                            showLogoutConfirm = true
                        } label: {
                            Text("退出登录").frame(maxWidth: .infinity)
                        }
                    }
                    .listRowBackground(Color.whatsubBgElev)
                    .confirmationDialog("退出登录？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                        Button("退出登录", role: .destructive) { appState.logout() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("退出后需重新用邮箱验证码登录。云端 library、语料库和已购权益不会丢失。")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.whatsubBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task { await reloadQuota() }
        }
    }

    // Reflects the actual unlock SOURCE (not just the website license): website
    // license / iOS 买断 / iOS 订阅 / 试用 / 未解锁. Priority mirrors
    // MeResponse.appUnlocked. (Subscription detail also shows in 云端同步.)
    @ViewBuilder
    private var licenseRow: some View {
        HStack {
            Text("授权状态").foregroundStyle(.whatsubInk)
            Spacer()
            if let user = appState.currentUser {
                if user.hasActiveLicense {
                    statusLabel("网站授权 · 有效", "checkmark.seal.fill", .green)
                } else if user.iosBuyout == true {
                    statusLabel("已买断", "checkmark.seal.fill", .whatsubAccent)
                } else if user.iosSubActive == true {
                    statusLabel("已订阅 Pro", "checkmark.seal.fill", .whatsubAccent)
                } else if isTrialActive(user) {
                    statusLabel("试用中", "clock.fill", .whatsubAccent)
                } else {
                    statusLabel("未解锁", "xmark.seal", .whatsubInkMuted)
                }
            } else {
                Text("查询中…").foregroundStyle(.whatsubInkFaint)
            }
        }
    }

    private func statusLabel(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    /// Within the free trial — or trial timing unknown (nil → fail-open, matching
    /// MeResponse.appUnlocked), so the row never says 未解锁 for someone who is
    /// actually in the app.
    private func isTrialActive(_ user: MeResponse) -> Bool {
        guard let exp = user.trialExpiresAt else { return true }
        return Int64(Date().timeIntervalSince1970 * 1000) < exp
    }
}
