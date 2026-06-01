import SwiftUI

/// Pre-session launcher for AI dialog practice over a video's vocab notebook.
/// Lets the user pick 2–5 of the saved phrases, choose a turn cap (3/5/10/∞),
/// and starts QuickChatView. Vocab books are smaller than the personal corpus
/// so there's no auto-pick mode — manual selection only.
struct VocabPracticeLauncherView: View {
    let items: [VocabItem]
    /// Called when 开始对话 is tapped. turnCap = nil means unlimited.
    let onStart: (PhraseSelector.Pick, _ turnCap: Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    @AppStorage("quickchat.last-turn-choice") private var savedTurnChoice: String = TurnChoice.five.rawValue
    @State private var turnChoice: TurnChoice = .five
    @State private var selectedIds: Set<String> = []

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

    private let maxPicks = 5
    private let minPicks = 2

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    listSection
                    turnsSection
                    Color.clear.frame(height: 80)
                }
                .padding(20)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("AI 对话练习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) { startButton }
            .onAppear {
                if let saved = TurnChoice(rawValue: savedTurnChoice) {
                    turnChoice = saved
                }
            }
        }
    }

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选 \(minPicks)–\(maxPicks) 个词汇")
                    .font(.caption).foregroundStyle(.whatsubInkFaint)
                Spacer()
                Text("\(selectedIds.count) / \(maxPicks)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selectedIds.count >= minPicks ? .whatsubAccent : .whatsubInkMuted)
            }
            if items.isEmpty {
                Text("这个词汇本是空的。先在视频里长按字幕收藏一些短语。")
                    .font(.footnote).foregroundStyle(.whatsubInkMuted)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgElev))
            } else {
                VStack(spacing: 6) {
                    ForEach(items) { item in row(item) }
                }
            }
        }
    }

    private func row(_ item: VocabItem) -> some View {
        let isSelected = selectedIds.contains(item.id)
        let isAtCap = !isSelected && selectedIds.count >= maxPicks
        return Button {
            toggle(item.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.whatsubAccent : Color.whatsubInkFaint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.phrase)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.whatsubInk)
                    if !item.note.isEmpty {
                        Text(item.note)
                            .font(.caption).foregroundStyle(.whatsubInkMuted)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Text(item.sentenceEn)
                        .font(.caption2).foregroundStyle(.whatsubInkFaint)
                        .lineLimit(1).truncationMode(.tail)
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

    private func toggle(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else if selectedIds.count < maxPicks {
            selectedIds.insert(id)
        }
    }

    private var turnsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("对话轮数").font(.caption).foregroundStyle(.whatsubInkFaint)
            Picker("", selection: $turnChoice) {
                ForEach(TurnChoice.allCases) { c in Text(c.label).tag(c) }
            }
            .pickerStyle(.segmented)
            Text(turnChoice == .unlimited
                 ? "无限轮：除非你手动按「结束」，否则一直聊下去。"
                 : "到 \(turnChoice.rawValue) 轮 AI 会自然收尾。")
                .font(.caption).foregroundStyle(.whatsubInkMuted)
        }
    }

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

    private var canStart: Bool { selectedIds.count >= minPicks }

    private func handleStart() {
        savedTurnChoice = turnChoice.rawValue
        let picked = items.filter { selectedIds.contains($0.id) }
        guard !picked.isEmpty else { return }
        let sessionPhrases = picked.map { item in
            SessionPhrase(
                phraseNormalized: item.phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                phraseRaw: item.phrase,
                // The user-typed note is the closest thing to a Chinese meaning we
                // have for vocab items. May be empty — QuickChatPrompts falls back
                // to "(略)" in that case so the LLM still sees a phrase entry.
                meaningZh: item.note.isEmpty ? nil : item.note,
                // No usageNote for vocab — VocabItem doesn't store one.
                usageNote: nil,
                // sentenceEn is the original cue context — exactly what the stuck-
                // card review needs.
                contextSentence: item.sentenceEn,
                sourceKind: "youtube",
                sourceURL: "",
                sourceTimestampSec: nil,
                tags: []
            )
        }
        let pick = PhraseSelector.Pick(phrases: sessionPhrases, suggestedTag: nil)
        let cap = turnChoice.cap
        dismiss()
        // Same 350ms delay pattern as QuickChatLauncherView — SwiftUI doesn't
        // reliably swap sheets when one dismisses and the parent presents
        // another in the same render cycle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onStart(pick, cap)
        }
    }
}
