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
    /// Manual entry for the AI 数据使用说明 sheet. The same gate auto-shows
    /// on first authed launch (WhatsubMobileApp.ContentView), but a user
    /// who swipe-dismissed it or wants to re-read needs a non-restart path.
    /// 2026-06-09 (App Store Guideline 5.1.1/5.1.2 follow-up).
    @State private var showAIConsent = false
    /// 锁屏继续播放 — 2026-06-17. Persists to UserDefaults via @AppStorage.
    /// Default false to match pre-2026-06-17 behavior (video pauses on lock)
    /// and to give Apple Review the user-opt-in framing for the re-added
    /// UIBackgroundModes: audio entitlement. Read at background-entry by
    /// BackgroundAudioCoordinator using the same UserDefaults key.
    @AppStorage(BackgroundAudioCoordinator.preferenceKey)
    private var backgroundPlaybackEnabled: Bool = false
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

    /// Pulled on first appear AND on pull-to-refresh. The
    /// `store.reportCurrentEntitlements()` step (added 2026-06-07) catches
    /// the "post-update shows 未订阅" case: an existing iOS subscription
    /// that survived an app update never fires through `Transaction.updates`,
    /// so the backend's `/me.hasActiveSubscription` can lag the device.
    /// Re-reporting verified JWSes to `/iap/verify` (idempotent) before
    /// calling `refreshMe()` makes the pulled-down page snap to the right
    /// state every time.
    private func reloadQuota() async {
        await store.reportCurrentEntitlements()
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
                        // 2026-06-11 — was "if currentUser.hasActiveSubscription ==
                        // true". Apple Guideline 2.1(b) rejected build 299:
                        // reviewer purchased via StoreKit but the /verify
                        // round-trip to our backend failed transiently, so
                        // refreshMe still returned hasActiveSubscription=false
                        // → UI showed 「未订阅」 → reviewer logged it as
                        // "purchase not credited". Now we OR in
                        // `store.hasLocalSub` (StoreKit's local verification
                        // of an active sub on this device) — so the moment
                        // Apple confirms the sub via the sandbox/StoreKit,
                        // the UI shows Pro even if our backend hasn't yet
                        // caught up. The backend retry + refreshMe still
                        // happens in the background.
                        let proActive = appState.currentUser?.hasActiveSubscription == true
                            || store.hasLocalSub
                        if proActive {
                            Label(
                                (appState.currentUser?.iosSubActive == true || store.hasLocalSub)
                                    ? "已订阅 · \(subPlanName)"
                                    : "已订阅 Pro",
                                systemImage: "checkmark.seal.fill"
                            )
                            .foregroundStyle(.whatsubAccent)
                            if appState.currentUser?.iosSubActive == true || store.hasLocalSub {
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

                    Section("播放") {
                        // 锁屏继续播放 — opt-in for UIBackgroundModes: audio
                        // (2026-06-17). Default OFF. When ON: Library video
                        // audio survives screen lock + lock-screen card
                        // shows title/thumb + ±15s skip. When OFF:
                        // BackgroundAudioCoordinator pauses the player on
                        // didEnterBackground (matches pre-2026-06-17 behavior).
                        Toggle(isOn: $backgroundPlaybackEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("锁屏继续播放", systemImage: "lock.iphone")
                                    .foregroundStyle(.whatsubInk)
                                Text("锁屏或切换 app 后，视频音频继续播放")
                                    .font(.caption)
                                    .foregroundStyle(.whatsubInkMuted)
                            }
                        }
                        .tint(.whatsubAccent)
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
                        // AI 数据使用说明 — manual entry to the same
                        // AIConsentGate that auto-shows on first launch.
                        // Lets a user re-read the disclosure or click
                        // 「同意」 if the auto-presentation missed (e.g.,
                        // cold-launch race or older build). 2026-06-09.
                        Button {
                            showAIConsent = true
                        } label: {
                            HStack {
                                Label("AI 数据使用说明", systemImage: "checkmark.shield")
                                    .foregroundStyle(.whatsubInk)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.whatsubInkFaint)
                            }
                        }
                        .buttonStyle(.borderless)
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
                // Pull-to-refresh added 2026-06-07. Same loader as the
                // first-appear `.task`: re-report entitlements → refreshMe →
                // re-pull quotas. Lets the user resolve "刚续费了为什么还显示
                // 未订阅" themselves without restarting the app.
                .refreshable { await reloadQuota() }
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
            // AI 数据使用说明 sheet — same view the app root auto-presents
            // on first launch. Mounted here so the manual entry button
            // works regardless of whether the auto-presentation already
            // ran or not. Idempotent: re-tapping "同意并继续" just
            // re-sets the flag to true (no-op).
            .sheet(isPresented: $showAIConsent) {
                AIConsentGate(presenting: $showAIConsent)
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
                } else if user.hasActiveSubscription == true || store.hasLocalSub {
                    // Same hasLocalSub OR added 2026-06-11 — backend may lag
                    // a fresh StoreKit purchase by a few seconds (transient
                    // /verify failure + retry). Showing Pro the moment
                    // StoreKit confirms locally fixes Apple's Guideline
                    // 2.1(b) "purchase not credited" rejection.
                    statusLabel("已订阅 Pro", "checkmark.seal.fill", .whatsubAccent)
                } else {
                    statusLabel("免费版", "person.crop.circle", .whatsubInkMuted)
                }
            } else if store.hasLocalSub {
                // No /me response yet (cold launch + offline + had Pro
                // before). Trust StoreKit's local entitlement so we don't
                // mislabel a paying user as 查询中…
                statusLabel("已订阅 Pro", "checkmark.seal.fill", .whatsubAccent)
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
