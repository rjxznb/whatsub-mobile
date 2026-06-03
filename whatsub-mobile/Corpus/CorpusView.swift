import SwiftUI

struct CorpusView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: StoreManager
    @StateObject private var vm = CorpusViewModel()

    private var token: String? { appState.session?.sessionToken }
    @State private var showQuiz = false
    @State private var showAddPhrase: Bool = false
    @State private var showSubscribe = false
    /// 2026-06-03 Stage 4: persisted choice between flat (each phrase a row) and
    /// grouped (each video a card with its phrases nested). UserDefaults so it
    /// survives app launches.
    @AppStorage("corpus.mine.layout") private var mineLayoutRaw: String = MineLayout.flat.rawValue
    private var mineLayout: MineLayout {
        get { MineLayout(rawValue: mineLayoutRaw) ?? .flat }
    }
    enum MineLayout: String { case flat, byVideo }
    @State private var quickChatPick: PhraseSelector.Pick?
    @State private var quickChatColdStart: Bool = false
    @State private var showQuickChatLauncher: Bool = false
    @State private var pendingTurnCap: Int? = 5    // set by the launcher, consumed when sheet opens
    /// Pending delete confirmation — set when the user swipes-to-delete a
    /// flat row OR long-presses → Delete in the grouped view. The alert
    /// is bound to this presence; tapping 删除 calls vm.delete.
    @State private var pendingDelete: MineItem?
    /// One-shot 警示 text — surfaces "(此条无 id, 请下拉刷新)" when the user
    /// tries to delete a row that pre-dated the id decode patch.
    @State private var deleteWarning: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("语料库")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.whatsubInk)
                    if vm.scope == .mine {
                        Button { showAddPhrase = true } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.whatsubAccent)
                        }
                        .accessibilityLabel("添加短语")
                    }
                    Spacer()
                    Button { tapQuickChat() } label: {
                        Label("对话陪练", systemImage: "bubble.left.and.bubble.right")
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.whatsubAccent)
                    }
                    Button { showQuiz = true } label: {
                        Label("单词卡", systemImage: "rectangle.stack.badge.play")
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.whatsubAccent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 8)

                Picker("", selection: Binding(
                    get: { vm.scope },
                    set: { s in Task { if let t = token { await vm.switchScope(s, token: t) } } }
                )) {
                    Text("公共").tag(CorpusScope.publicCorpus)
                    Text("我的").tag(CorpusScope.mine)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.bottom, 8)

                if !vm.tags.isEmpty { tagChips }

                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.whatsubBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { phrase in
                PhraseDetailView(phrase: phrase)
            }
            .task { if let t = token, !vm.loadedOnce { await vm.reload(token: t) } }
            .refreshable { if let t = token { await vm.reload(token: t) } }
            .sheet(isPresented: $showQuiz) {
                QuizView().environmentObject(appState)
            }
            .sheet(isPresented: $showAddPhrase) {
                AddCorpusPhraseView(
                    availableTags: vm.tags,
                    onSuccess: {
                        if let t = token {
                            Task { await vm.reload(token: t) }
                        }
                    }
                )
                .environmentObject(appState)
            }
            // Pro subscription upsell — presented when user taps "订阅 Pro" on the
            // 公共语料库 lock. Attached at the root so a Picker / List re-render
            // mid-animation can't tear it down (same gotcha noted in MeView).
            .sheet(isPresented: $showSubscribe) {
                SubscribeSheet(onPurchased: {
                    Task {
                        await appState.refreshMe()
                        if let t = token { await vm.reload(token: t) }
                    }
                })
                .environmentObject(store)
            }
            .sheet(item: $quickChatPick) { pick in
                QuickChatView(phrases: pick.phrases, suggestedTag: pick.suggestedTag, maxTurns: pendingTurnCap)
                    .environmentObject(appState)
                    // Prevent system swipe-down-to-dismiss on the chat sheet
                    // (2026-06-03): the chat is mid-session when the user is
                    // mid-utterance; an accidental down-swipe shouldn't kill
                    // the AI's reply. ALSO: our own down-swipe gesture is for
                    // dismissing the keyboard — without this, BOTH fire and
                    // the sheet wins. Exit is now exclusively the 关闭 button.
                    .interactiveDismissDisabled(true)
            }
            .sheet(isPresented: $showQuickChatLauncher) {
                QuickChatLauncherView(mine: vm.mine) { pick, turnCap in
                    pendingTurnCap = turnCap
                    quickChatPick = pick
                }
            }
            .alert("语料不够", isPresented: $quickChatColdStart) {
                Button("好") { quickChatColdStart = false }
            } message: {
                Text("先用插件划词收藏 3 个以上短语就可以开练。")
            }
            .alert(
                "从云端删除？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { item in
                Button("删除", role: .destructive) {
                    if let tok = token {
                        let target = item
                        Task {
                            let outcome = await vm.delete(item: target, token: tok)
                            await MainActor.run {
                                if case .unsupported = outcome {
                                    deleteWarning = "这条短语来自旧版缓存，下拉刷新一次再试"
                                } else if case .failed(let msg) = outcome {
                                    deleteWarning = msg
                                }
                            }
                        }
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { item in
                Text("「\(item.phraseRaw)」将从云端语料库移除。其他端在下次刷新后也会同步消失。")
            }
            .alert(
                "删除失败",
                isPresented: Binding(
                    get: { deleteWarning != nil },
                    set: { if !$0 { deleteWarning = nil } }
                ),
                presenting: deleteWarning
            ) { _ in
                Button("好", role: .cancel) { deleteWarning = nil }
            } message: { msg in
                Text(msg)
            }
        }
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.tags) { t in
                    let on = vm.selectedTags.contains(t.tag)
                    Text("\(t.tag) \(t.count)")
                        .font(.caption).fontWeight(on ? .semibold : .regular)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(on ? Color.whatsubAccent.opacity(0.25) : Color.whatsubBgElev, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Color.whatsubAccent : .clear, lineWidth: 1))
                        .foregroundStyle(on ? .whatsubAccent : .whatsubInkSoft)
                        .onTapGesture { if let tok = token { Task { await vm.toggleTag(t.tag, token: tok) } } }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.browse.isEmpty && vm.mine.isEmpty {
            Spacer(); ProgressView().tint(.whatsubAccent); Spacer()
        } else if vm.licenseLocked {
            // Public corpus is a Pro-tier capability (2026-05-28 policy shift).
            // Centered lock card + actionable 订阅 Pro button → SubscribeSheet.
            // 我的 tab is still free, so the copy reassures users they can keep
            // building their personal corpus while they decide.
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.whatsubAccent)
                Text("公共语料库需 Pro 会员")
                    .font(.headline).foregroundStyle(.whatsubInk)
                Text("订阅 Pro 解锁全部公共语料库；\n「我的」语料库始终免费可用。")
                    .font(.footnote).foregroundStyle(.whatsubInkMuted)
                    .multilineTextAlignment(.center)
                Button {
                    showSubscribe = true
                } label: {
                    Label("订阅 Pro · 解锁公共语料库", systemImage: "star.circle.fill")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Color.whatsubAccent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                Spacer()
            }
            .padding(32)
        } else if let err = vm.errorMessage {
            centered(icon: "exclamationmark.triangle", title: err, sub: "下拉重试")
        } else if vm.scope == .publicCorpus {
            if vm.browse.isEmpty {
                centered(icon: "books.vertical", title: "公共语料库暂无内容", sub: "管理员添加后这里会出现")
            } else {
                List(vm.browse) { p in
                    NavigationLink(value: p.phraseNormalized) {
                        PhraseRow(raw: p.phraseRaw, meaning: p.meaningZh, sub: nil, tags: p.tags)
                    }.listRowBackground(Color.whatsubBgElev)
                }.scrollContentBackground(.hidden)
            }
        } else {
            if vm.mine.isEmpty {
                centered(icon: "bookmark", title: "还没有收藏的短语", sub: "用 whatSub 插件在网页/视频里保存短语，\n这里就能看到")
            } else {
                let used = vm.corpusQuota?.used ?? vm.mineTotal
                let limit = vm.corpusQuota?.limit ?? ((appState.currentUser?.iosSubActive == true) ? 1000 : 50)
                HStack {
                    Text("个人语料 \(used)/\(limit)")
                        .font(.caption)
                        .foregroundStyle(.whatsubInkMuted)
                    Spacer()
                    // Layout toggle: list view (each phrase a row) vs. grouped
                    // by source video. Compact icon picker — wider segmented
                    // text labels would crowd the quota line on iPhone SE.
                    Picker("", selection: Binding(
                        get: { mineLayout },
                        set: { mineLayoutRaw = $0.rawValue }
                    )) {
                        Image(systemName: "list.bullet").tag(MineLayout.flat)
                        Image(systemName: "rectangle.stack").tag(MineLayout.byVideo)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)
                }
                .padding(.horizontal, 16).padding(.bottom, 4)

                switch mineLayout {
                case .flat:
                    List(vm.mine) { m in
                        NavigationLink(value: m.phraseNormalized) {
                            PhraseRow(raw: m.phraseRaw, meaning: m.meaningZh, sub: m.contextSentence, tags: m.tags)
                        }
                        .listRowBackground(Color.whatsubBgElev)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = m
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }.scrollContentBackground(.hidden)
                case .byVideo:
                    GroupedMineView(
                        items: vm.mine,
                        libraryThumbnails: vm.libraryThumbnails,
                        onDelete: { item in pendingDelete = item }
                    )
                }
            }
        }
    }

    private func tapQuickChat() {
        // Launcher handles both auto-pick and manual flows + turn-cap choice.
        if vm.mine.count < 2 {
            // Even manual mode needs 2 phrases — cold-start prompt.
            quickChatColdStart = true
        } else {
            showQuickChatLauncher = true
        }
    }

    private func centered(icon: String, title: String, sub: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.whatsubAccent)
            Text(title).font(.headline).foregroundStyle(.whatsubInk)
            Text(sub).font(.footnote).foregroundStyle(.whatsubInkMuted).multilineTextAlignment(.center)
            Spacer()
        }.padding(32)
    }
}

private struct PhraseRow: View {
    let raw: String
    let meaning: String?
    let sub: String?
    let tags: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(raw).font(.system(size: 17, weight: .semibold)).foregroundStyle(.whatsubInk)
            if let m = meaning, !m.isEmpty {
                Text(m).font(.subheadline).foregroundStyle(.whatsubInkSoft).lineLimit(2)
            }
            if let s = sub, !s.isEmpty {
                Text(s).font(.caption).foregroundStyle(.whatsubInkMuted).lineLimit(1)
            }
            if !tags.isEmpty {
                Text(tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption2).foregroundStyle(.whatsubInkFaint)
            }
        }.padding(.vertical, 4)
    }
}
