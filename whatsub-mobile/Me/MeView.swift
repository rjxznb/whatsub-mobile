import SwiftUI
import StoreKit

struct MeView: View {
    @EnvironmentObject var appState: AppState
    @State private var quota: LibraryQuota?
    @State private var corpusQ: CorpusQuota?
    @EnvironmentObject var store: StoreManager
    @State private var showManageSubscriptions = false
    @State private var showLogoutConfirm = false
    @State private var showDeleteAccountConfirm = false
    @State private var deletingAccount = false
    @State private var deleteAccountError: String?
    @State private var showSubscribe = false
    // (showPhotoCapture / showLiveScene removed 2026-06-05 — the 拍照翻译
    // (was 拍照识别短语) + 实景口语练习 entries moved to the new 「眼前」
    // tab. 导入视频 also gone — now a "+" button on the Library tab.
    // showPendingPhrases removed 2026-06-07 — the pending-staging area
    // is now shown inline in each video's 收藏 tab with per-row ☁️
    // upload buttons; a global list view + sheet was redundant.)

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
                        // Suppress the upsell for ANY active subscriber — iOS
                        // StoreKit OR a website/plugin Alipay 时段会员 (same email).
                        // Gating on hasActiveSubscription (not iosSubActive) stops a
                        // cross-platform web subscriber from being shown the 订阅 Pro
                        // button and double-charging via StoreKit. The 管理订阅
                        // (StoreKit) button only applies to an iOS-originated sub;
                        // a web sub is managed on the web/插件, so we just show the
                        // subscribed badge. We do NOT add any "buy on web" steering
                        // here (App Store 3.1.1).
                        if appState.currentUser?.hasActiveSubscription == true {
                            Label(
                                appState.currentUser?.iosSubActive == true
                                    ? "已订阅 · \(subPlanName)"
                                    : "已订阅 Pro",
                                systemImage: "checkmark.seal.fill"
                            )
                            .foregroundStyle(.whatsubAccent)
                            if appState.currentUser?.iosSubActive == true {
                                Button("管理订阅") { showManageSubscriptions = true }
                                    .foregroundStyle(.whatsubAccent)
                            }
                        } else {
                            // Inline blurb removed 2026-06-04 per user feedback —
                            // the full feature list lives inside SubscribeSheet,
                            // and the button label below is now the only
                            // pre-tap copy in this row.
                            Button {
                                showSubscribe = true
                            } label: {
                                Label("订阅 Pro · 解锁 AI + 50 视频 + 1000 语料库", systemImage: "star.circle.fill")
                                    .foregroundStyle(.whatsubAccent)
                            }
                        }
                    }
                    .listRowBackground(Color.whatsubBgElev)

                    Section("关于") {
                        LabeledContent("版本", value: versionString)
                            .foregroundStyle(.whatsubInk)
                        Link("官网 whatsub.eversay.cc", destination: URL(string: "https://whatsub.eversay.cc")!)
                            .foregroundStyle(.whatsubAccent)
                    }
                    .listRowBackground(Color.whatsubBgElev)

                    Section("工具") {
                        // 2026-06-05: 导入视频 / 拍照翻译 / 实景口语练习 all
                        // moved to dedicated surfaces (Library "+" toolbar
                        // + 「眼前」 tab) — this section is now strictly
                        // settings + maintenance.
                        NavigationLink(destination: LlmSettingsView()) {
                            Label("LLM 设置", systemImage: "cpu")
                                .foregroundStyle(.whatsubInk)
                        }
                        NavigationLink(destination: VoiceSettingsView()) {
                            Label("语音设置", systemImage: "speaker.wave.2")
                                .foregroundStyle(.whatsubInk)
                        }
                        NavigationLink(destination: ImportQueueView()) {
                            Label("导入队列", systemImage: "tray.and.arrow.down")
                                .foregroundStyle(.whatsubInk)
                        }
                    }
                    .listRowBackground(Color.whatsubBgElev)
                    // (Local 词汇暂存区 entry removed build 248. Pending
                    // 暂存 entry removed 2026-06-07 — the pending phrases
                    // are now shown inline in each video's 收藏 tab with
                    // per-row ☁️ upload buttons; a global cross-video list
                    // turned out redundant.)

                    Section {
                        Button(role: .destructive) {
                            showLogoutConfirm = true
                        } label: {
                            Text("退出登录").frame(maxWidth: .infinity)
                        }
                        // List rows default to a 16pt leading separator inset
                        // (sized for hypothetical leading icons). Both rows
                        // here are centered text — push the separator's left
                        // edge all the way to 0 so it spans the full row.
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        // Apple Guideline 5.1.1(v): any app supporting account
                        // creation must offer in-app account deletion. Distinct
                        // from 退出登录 — this is a hard cascade-delete that
                        // can't be undone.
                        Button(role: .destructive) {
                            showDeleteAccountConfirm = true
                        } label: {
                            if deletingAccount {
                                HStack {
                                    ProgressView().tint(.red)
                                    Text("正在删除…")
                                }.frame(maxWidth: .infinity)
                            } else {
                                Text("删除账号").frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(deletingAccount)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        if let err = deleteAccountError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .listRowBackground(Color.whatsubBgElev)
                    .confirmationDialog("退出登录？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                        Button("退出登录", role: .destructive) { appState.logout() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("退出后需重新用邮箱验证码登录。云端 library、语料库和已购权益不会丢失。")
                    }
                    .confirmationDialog("删除账号？", isPresented: $showDeleteAccountConfirm, titleVisibility: .visible) {
                        Button("永久删除我的账号", role: .destructive) { Task { await performDeleteAccount() } }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("此操作将永久删除你的全部云端数据：library 视频和字幕、个人语料库、订阅状态、登录会话。OSS 上的视频也会被清除。**不可恢复**。\n\n网站授权 / iOS 订阅交易记录会保留（用于退款审计），下次用同一邮箱注册不会恢复你的旧云端数据。")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.whatsubBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task { await reloadQuota() }
            // Attached to the stable root, NOT the 云端同步 Section: that Section
            // re-renders when quota/store @Published update on first appear, which
            // tore down a Section-attached sheet → it opened then immediately
            // dismissed on the first 订阅 tap (worked after products were cached).
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
            .sheet(isPresented: $showSubscribe) {
                SubscribeSheet(onPurchased: { Task { await reloadQuota() } })
                    .environmentObject(store)
            }
            // (photo + live-scene sheets moved to CameraTabView 2026-06-05;
            //  待同步暂存 sheet removed 2026-06-07.)
        }
    }

    // Reflects the user's Pro entitlement source: website license / iOS 订阅 /
    // 免费版. Post the 2026-05-28 policy shift, the app has only two modes:
    // 免费版 (everything free-tier accessible) or 已订阅 Pro (cloud-quota
    // expansion + public corpus). 试用 and 买断 are gone from the product.
    @ViewBuilder
    private var licenseRow: some View {
        HStack {
            Text("授权状态").foregroundStyle(.whatsubInk)
            Spacer()
            if let user = appState.currentUser {
                if user.hasActiveLicense {
                    statusLabel("网站授权 · 有效", "checkmark.seal.fill", .green)
                } else if user.hasActiveSubscription == true {
                    // Any active subscription — iOS StoreKit OR web/插件 Alipay
                    // 时段会员 (same email). Was iosSubActive, which mislabeled a
                    // cross-platform web subscriber as 免费版.
                    statusLabel("已订阅 Pro", "checkmark.seal.fill", .whatsubAccent)
                } else {
                    statusLabel("免费版", "person.crop.circle", .whatsubInkMuted)
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

    /// DELETE /api/license/auth/account → on success, log the user out so
    /// they land back on AuthGateView with their session invalidated. The
    /// backend cascade is exhaustive (library, corpus, sessions,
    /// entitlements); failures here are unusual but we surface the message.
    /// For the demo account (DEMO_REVIEW_EMAIL) the backend returns
    /// {ok:true,demo:true} without touching the DB — Apple's reviewer flow
    /// looks identical from the iOS side.
    private func performDeleteAccount() async {
        guard let token = appState.session?.sessionToken else { return }
        deletingAccount = true
        deleteAccountError = nil
        do {
            try await WhatsubAPI.shared.deleteAccount(token: token)
            // Local cleanup mirrors what backend already did server-side.
            appState.logout()
        } catch let e as APIError {
            deleteAccountError = e.chinese
        } catch {
            deleteAccountError = "删除失败：\(error.localizedDescription)"
        }
        deletingAccount = false
    }
}
