import SwiftUI

/// Pre-session launcher. Lets the user (1) pick phrases — auto-3 by default,
/// or manually select up to maxManualPicks of their own — and (2) set the
/// conversation turn cap (3, 5, 10, or unlimited). Tap 开始对话 to construct
/// a `Plan` and hand off to QuickChatView.
struct QuickChatLauncherView: View {
    let mine: [MineItem]
    /// Called when user taps 「开始对话」 with the final pick + turn cap.
    /// turnCap = nil means unlimited.
    let onStart: (PhraseSelector.Pick, _ turnCap: Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable { case auto, manual }

    @State private var mode: Mode = .auto
    @State private var turnChoice: TurnChoice = .five
    @State private var selectedKeys: Set<String> = []
    @AppStorage("quickchat.last-turn-choice") private var savedTurnChoice: String = TurnChoice.five.rawValue
    @State private var showIntro: Bool = false
    @State private var startFailureMessage: String? = nil

    enum TurnChoice: String, CaseIterable, Identifiable {
        case three = "3"
        case five = "5"
        case ten = "10"
        case unlimited = "∞"
        var id: String { rawValue }
        var label: String { rawValue }
        var cap: Int? {
            switch self {
            case .three: return 3
            case .five: return 5
            case .ten: return 10
            case .unlimited: return nil
            }
        }
    }

    /// Manual mode cap on selections.
    private let maxManualPicks = 5
    /// Manual mode minimum.
    private let minManualPicks = 2

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    modeSection
                    if mode == .manual { manualSection }
                    turnsSection
                    Color.clear.frame(height: 80)   // room above the floating start button
                }
                .padding(20)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("对话陪练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showIntro = true } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.whatsubAccent)
                    }
                    .accessibilityLabel("使用教程")
                }
            }
            .sheet(isPresented: $showIntro) {
                QuickChatIntroView()
            }
            .overlay(alignment: .bottom) { startButton }
            .alert("无法开始", isPresented: Binding(
                get: { startFailureMessage != nil },
                set: { if !$0 { startFailureMessage = nil } }
            )) {
                Button("好的", role: .cancel) { startFailureMessage = nil }
            } message: {
                Text(startFailureMessage ?? "")
            }
            .onAppear {
                if let saved = TurnChoice(rawValue: savedTurnChoice) {
                    turnChoice = saved
                }
                if !QuickChatIntroView.hasAcknowledged {
                    showIntro = true
                }
            }
        }
    }

    // ---- mode segmented control ----
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选词").font(.caption).foregroundStyle(.whatsubInkFaint)
            Picker("", selection: $mode) {
                Text("随机抽 3 个").tag(Mode.auto)
                Text("自选").tag(Mode.manual)
            }
            .pickerStyle(.segmented)
            if mode == .auto {
                Text("系统挑「认得了但还没说会」的 3 个短语，配一个能容下它们的小情景。")
                    .font(.caption).foregroundStyle(.whatsubInkMuted)
            }
        }
    }

    // ---- manual phrase list ----
    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选 \(minManualPicks)–\(maxManualPicks) 个短语")
                    .font(.caption).foregroundStyle(.whatsubInkFaint)
                Spacer()
                Text("\(selectedKeys.count) / \(maxManualPicks)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selectedKeys.count >= minManualPicks ? .whatsubAccent : .whatsubInkMuted)
            }
            if mine.isEmpty {
                Text("个人语料库还没有短语，先用插件划词收藏几个。")
                    .font(.footnote).foregroundStyle(.whatsubInkMuted)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgElev))
            } else {
                VStack(spacing: 6) {
                    ForEach(mine) { item in phraseRow(item) }
                }
            }
        }
    }

    private func phraseRow(_ item: MineItem) -> some View {
        let isSelected = selectedKeys.contains(item.phraseNormalized)
        let isAtCap = !isSelected && selectedKeys.count >= maxManualPicks
        return Button {
            togglePick(item.phraseNormalized)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.whatsubAccent : Color.whatsubInkFaint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.phraseRaw)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.whatsubInk)
                    if let meaning = item.meaningZh, !meaning.isEmpty {
                        Text(meaning)
                            .font(.caption)
                            .foregroundStyle(.whatsubInkMuted)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgElev))
            .opacity(isAtCap ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isAtCap)
    }

    private func togglePick(_ key: String) {
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else if selectedKeys.count < maxManualPicks {
            selectedKeys.insert(key)
        }
    }

    // ---- turn picker ----
    private var turnsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("对话轮数").font(.caption).foregroundStyle(.whatsubInkFaint)
            Picker("", selection: $turnChoice) {
                ForEach(TurnChoice.allCases) { c in
                    Text(c.label).tag(c)
                }
            }
            .pickerStyle(.segmented)
            Text(turnChoice == .unlimited
                 ? "无限轮：除非你手动按「结束」，否则一直聊下去（小心 BYOK token 费用）。"
                 : "到 \(turnChoice.rawValue) 轮 AI 会自然收尾，自动进入掌握度统计。")
                .font(.caption).foregroundStyle(.whatsubInkMuted)
        }
    }

    // ---- start button (floating at bottom) ----
    @ViewBuilder
    private var startButton: some View {
        Button { handleStart() } label: {
            Text("开始对话")
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(canStart ? Color.whatsubAccent : Color.whatsubInkFaint, in: Capsule())
        }
        .disabled(!canStart)
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
        .background(
            LinearGradient(colors: [.clear, Color.whatsubBg, Color.whatsubBg],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 100)
                .allowsHitTesting(false)
        )
    }

    private var canStart: Bool {
        switch mode {
        case .auto: return mine.count >= 3   // need ≥3 for auto-pick to succeed
        case .manual: return selectedKeys.count >= minManualPicks
        }
    }

    // ---- handler ----
    private func handleStart() {
        savedTurnChoice = turnChoice.rawValue
        let pick: PhraseSelector.Pick?
        switch mode {
        case .auto:
            let prodStore = ProductionProgressStore()
            let quizStore = QuizProgressStore()
            let smart = PhraseSelector.pick(
                from: mine,
                isRecognized: { quizStore.progress(for: $0).isMastered },
                productionMastered: { prodStore.progress(for: $0)?.masteredAt != nil },
                isDueForRepetition: { prodStore.isDueForRepetition(phrase: $0, now: Date().timeIntervalSince1970) },
                now: Date().timeIntervalSince1970
            )
            // Smart selector can return nil when the user's corpus is mostly
            // recently mastered (spaced-repetition window still open → all
            // candidates filtered as .excluded → fewer than 3 left). The
            // button label says "随机抽 3 个" so falling back to a literal
            // random pick is on-brand AND prevents the silent-no-op bug the
            // user reported (2026-06-02). canStart already guarantees
            // mine.count >= 3 so the prefix(3) is safe.
            if let smart {
                pick = smart
            } else if mine.count >= 3 {
                let shuffled = Array(mine.shuffled().prefix(3))
                let sessionPhrases = shuffled.map { m in
                    SessionPhrase(
                        phraseNormalized: m.phraseNormalized,
                        phraseRaw: m.phraseRaw,
                        meaningZh: m.meaningZh,
                        usageNote: m.usageNote,
                        contextSentence: m.contextSentence,
                        sourceKind: m.source.kind,
                        sourceURL: m.source.url,
                        sourceTimestampSec: m.source.timestampSec,
                        tags: m.tags
                    )
                }
                var tagCounts: [String: Int] = [:]
                for p in shuffled { for t in p.tags { tagCounts[t, default: 0] += 1 } }
                let majority = (shuffled.count / 2) + 1
                let dominant = tagCounts.filter { $0.value >= majority }.max(by: { $0.value < $1.value })?.key
                pick = PhraseSelector.Pick(phrases: sessionPhrases, suggestedTag: dominant)
            } else {
                pick = nil
            }
        case .manual:
            // Build a Pick directly from the user's picks. suggestedTag = the
            // most common tag among picks (if any 2+ share one) so the LLM
            // gets a scene hint; otherwise nil = LLM invents.
            let picked = mine.filter { selectedKeys.contains($0.phraseNormalized) }
            let sessionPhrases = picked.map { m in
                SessionPhrase(
                    phraseNormalized: m.phraseNormalized,
                    phraseRaw: m.phraseRaw,
                    meaningZh: m.meaningZh,
                    usageNote: m.usageNote,
                    contextSentence: m.contextSentence,
                    sourceKind: m.source.kind,
                    sourceURL: m.source.url,
                    sourceTimestampSec: m.source.timestampSec,
                    tags: m.tags
                )
            }
            // Find a dominant tag (>= half of picks share it).
            var tagCounts: [String: Int] = [:]
            for p in picked { for t in p.tags { tagCounts[t, default: 0] += 1 } }
            let majority = (picked.count / 2) + 1
            let dominant = tagCounts.filter { $0.value >= majority }.max(by: { $0.value < $1.value })?.key
            pick = PhraseSelector.Pick(phrases: sessionPhrases, suggestedTag: dominant)
        }
        guard let pick else {
            startFailureMessage = "至少需要 3 个个人语料库短语才能开启对话陪练。先去「语料库」收藏一些再回来试试。"
            return
        }
        dismiss()
        // Defer onStart slightly so the launcher sheet fully dismisses before the
        // QuickChatView sheet presents — SwiftUI gets confused when two sheets
        // try to swap simultaneously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onStart(pick, turnChoice.cap)
        }
    }
}
