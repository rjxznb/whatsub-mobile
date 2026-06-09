import SwiftUI

/// Pre-session launcher. Builds 237+ dropped the manual phrase-pick mode
/// (user feedback 2026-06-03: the segmented control + checkbox list was
/// noise; smart auto-pick is the right default for spaced-repetition
/// practice). What remains: an explanatory "what this is + how it works"
/// hero that doubles as onboarding, the turn-cap picker, the start button.
struct QuickChatLauncherView: View {
    let mine: [MineItem]
    /// Called when user taps 「开始对话」 with the final pick + turn cap.
    /// turnCap = nil means unlimited.
    let onStart: (PhraseSelector.Pick, _ turnCap: Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var turnChoice: TurnChoice = .five
    @AppStorage("quickchat.last-turn-choice") private var savedTurnChoice: String = TurnChoice.five.rawValue
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heroExplainer
                    workflowSteps
                    // selectorRules removed 2026-06-09 — phrase selection is
                    // now fully automatic (no UI choice exposed). The hero
                    // subtitle briefly mentions auto-selection; the detailed
                    // priority order lived in the desktop docs / source
                    // comments and isn't worth surfacing here.
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
            }
        }
    }

    // MARK: - Hero ("what is this")

    private var heroExplainer: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.whatsubAccent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("AI 英语口语陪练")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                // 2026-06-09 — 旧文案 "认得了但还没说会的 3 个短语" 太
                // 口语化,改成正式书面语 "未熟练掌握"。同时把"自动选择短语"
                // 这条信息提到小字里(原来在已删的 selectorRules 卡片里)。
                Text("从你语料库中自动选取 3 个未熟练掌握的短语，与 AI 进行一段情景对话，帮助你将被动认知转为主动表达。")
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.whatsubBgElev))
    }

    // MARK: - Workflow (3 steps, 2026-06-09)
    //
    // 旧版四步 (AI 起情景 / 长按球说话 / AI 听完接话 / 更新掌握度) 用户
    // 反馈"步骤太多",合并成三步,用词改成正式书面语。"长按球" 改成
    // "按住中央的圆点说话"；"AI 接话" 表达本质相同 → 合并到"对话进行"。

    private var workflowSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("使用步骤").font(.caption).foregroundStyle(.whatsubInkFaint)
            VStack(alignment: .leading, spacing: 12) {
                workflowRow(
                    number: 1,
                    title: "AI 设定情景",
                    detail: "系统自动选出 3 个目标短语，AI 据此设计一个能自然使用这些短语的对话场景，并由 AI 用英语开启对话。"
                )
                workflowRow(
                    number: 2,
                    title: "按住圆点用英语回应",
                    detail: "按住屏幕中央的圆点，用英语作答，松开即发送。语音自动转写为文字，无需手动输入。"
                )
                workflowRow(
                    number: 3,
                    title: "对话结束并更新掌握度",
                    detail: "AI 会逐轮判断每个目标短语是否被正确使用。对话结束后，已正确使用的短语将被标记为「已熟练」并进入间隔复习。"
                )
            }
        }
    }

    private func workflowRow(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.whatsubAccent))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.whatsubInk)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // (selectorRules + bullet helpers removed 2026-06-09 — phrase selection
    // is fully automatic now; the priority order lived in product copy that
    // we decided not to expose to end users. If we ever need to surface the
    // rules again, see commit history before 1da1497.)

    // MARK: - Turn picker

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

    // MARK: - Start button (floating)

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
        mine.count >= 3   // need ≥3 in corpus for auto-pick to succeed
    }

    // MARK: - Start handler

    private func handleStart() {
        savedTurnChoice = turnChoice.rawValue

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
        // candidates filtered as .excluded → fewer than 3 left). Fall
        // back to a literal random pick — keeps the launcher honest
        // ("随机选 3 个" is what the user sees).
        let pick: PhraseSelector.Pick?
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
                    sourceURL: m.source.url ?? "",
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

        guard let pick else {
            startFailureMessage = "至少需要 3 个个人语料库短语才能开启对话陪练。先去「语料库」收藏一些再回来试试。"
            return
        }
        dismiss()
        // Defer onStart slightly so the launcher sheet fully dismisses before
        // QuickChatView's sheet presents — SwiftUI gets confused when two
        // sheets try to swap simultaneously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onStart(pick, turnChoice.cap)
        }
    }
}
