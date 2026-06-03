import SwiftUI
import UIKit

/// 收藏卡 — opened by long-pressing a subtitle cue. The English sentence is shown
/// as tappable word chips: tap the word(s) you want (they highlight); the saved
/// phrase is those words (in sentence order), or the whole sentence if none are
/// tapped. A free-form 笔记 (TextEditor — robust Chinese IME) + an 「AI 查询」 button
/// that calls the user's configured LLM to translate + explain into the note.
struct CollectSheet: View {
    let cue: Cue
    let entryId: String
    let videoTitle: String
    /// The Library entry's YouTube origin id, if any. Recorded into source as
    /// `youtubeId` so the display layer can fall back to a YT embed if the
    /// Library entry is later deleted (the OSS object is gone, but the
    /// original YouTube video usually still exists). Pass nil for non-YT
    /// Library origins (e.g. Bilibili imports) — fallback won't be available.
    let youtubeId: String?

    @Environment(\.dismiss) private var dismiss
    private let tokens: [String]
    @State private var selected: Set<Int> = []
    @State private var note = ""
    @State private var aiLoading = false
    @State private var aiError: String?

    init(cue: Cue, entryId: String, videoTitle: String, youtubeId: String?) {
        self.cue = cue
        self.entryId = entryId
        self.videoTitle = videoTitle
        self.youtubeId = youtubeId
        self.tokens = cue.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    private var hasSelection: Bool { !selected.isEmpty }

    private var phraseToSave: String {
        if selected.isEmpty { return cue.text }
        return selected.sorted().map { tokens[$0] }.joined(separator: " ")
    }

    /// Selected words with an offline IPA and/or CN definition (in sentence order).
    private var dictEntries: [(id: Int, word: String, ipa: String?, def: String?)] {
        selected.sorted().compactMap { i in
            guard tokens.indices.contains(i) else { return nil }
            let w = tokens[i]
            let ipa = IPADict.shared.lookup(w)
            let def = ECDict.shared.define(w)
            guard ipa != nil || def != nil else { return nil }
            return (i, w, ipa, def)
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    wordCard
                    if !dictEntries.isEmpty { dictCard }
                    if !cue.highlightWords.isEmpty { glossCard }
                    noteField
                    previewRow
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.immediately)   // scrolling hides the keyboard
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("收藏到语料库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    // Wording (build 250+): the collect step now writes to a
                    // LOCAL staging queue (PendingPhraseStore) instead of
                    // POSTing to /api/corpus/contribute. The user reviews +
                    // syncs the queue separately from Library detail's
                    // "待同步 N" banner or 我的 → 工具 → 待同步暂存.
                    Button(hasSelection ? "加入暂存" : "整句加入暂存") { save() }
                        .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {   // explicit dismiss above the keyboard
                    Spacer()
                    Button("完成") { hideKeyboard() }
                }
            }
        }
    }

    private var wordCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasSelection ? "点词增减选择，再点「加入」" : "点句中的词来挑选要收藏的部分（或直接「加入整句」）")
                .font(.caption).foregroundStyle(.whatsubInkMuted)
            FlowLayout(spacing: 6, lineSpacing: 8) {
                ForEach(tokens.indices, id: \.self) { i in
                    let on = selected.contains(i)
                    Text(tokens[i])
                        .font(.system(size: 18, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.black : Color.whatsubInk)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(on ? Color.whatsubHighlight : Color.whatsubBgSoft)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture {
                            hideKeyboard()   // tapping a word also dismisses the note keyboard
                            if on { selected.remove(i) } else { selected.insert(i) }
                        }
                }
            }
            if !cue.translation.isEmpty {
                Text(cue.translation).font(.system(size: 15)).foregroundStyle(.whatsubInkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.whatsubBgElev))
    }

    private var dictCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("离线词典").font(.caption).foregroundStyle(.whatsubInkMuted)
            ForEach(dictEntries, id: \.id) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(e.word).font(.subheadline.weight(.semibold)).foregroundStyle(.whatsubInk)
                        if let ipa = e.ipa {
                            Text("/\(ipa)/").font(.caption).foregroundStyle(.whatsubAccent)
                        }
                    }
                    if let def = e.def {
                        Text(def).font(.caption).foregroundStyle(.whatsubInkSoft)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.whatsubBgElev))
    }

    private var glossCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 释义参考").font(.caption).foregroundStyle(.whatsubInkMuted)
            ForEach(cue.highlightWords, id: \.self) { w in
                HStack(alignment: .top, spacing: 8) {
                    Text(w).font(.subheadline.weight(.semibold)).foregroundStyle(.whatsubHighlight)
                    VStack(alignment: .leading, spacing: 2) {
                        if let t = cue.highlightTranslations[w], !t.isEmpty {
                            Text(t).font(.subheadline).foregroundStyle(.whatsubInk)
                        }
                        if let n = cue.keyNotes[w], !n.isEmpty {
                            Text(n).font(.caption).foregroundStyle(.whatsubInkSoft)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.whatsubBgElev))
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("笔记").font(.caption).foregroundStyle(.whatsubInkMuted)
                Spacer()
                Button {
                    Task { await runAI() }
                } label: {
                    HStack(spacing: 4) {
                        if aiLoading { ProgressView().scaleEffect(0.7) }
                        else { Image(systemName: "sparkles") }
                        Text(aiLoading ? "AI 查询中…" : "AI 翻译 + 解释")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.whatsubAccent)
                }
                .disabled(aiLoading)
            }
            // TextEditor (not TextField axis:.vertical) — the latter has flaky CJK/
            // 中文 IME composition; TextEditor handles multiline + Chinese reliably.
            TextEditor(text: $note)
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgSoft))
                .foregroundStyle(.whatsubInk)
            if let e = aiError {
                Text(e).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private var previewRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("将保存：").font(.footnote).foregroundStyle(.whatsubInkMuted)
            Text(phraseToSave).font(.footnote.weight(.medium)).foregroundStyle(.whatsubHighlight)
            Spacer(minLength: 0)
            if hasSelection {
                Button("清空") { selected.removeAll() }.font(.caption).foregroundStyle(.whatsubAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Calls the user's configured LLM (我的 → LLM 设置) to translate + explain the
    /// phrase-to-save in its sentence context, and writes the result into the note.
    @MainActor
    private func runAI() async {
        let settings = LlmSettingsStore.load()
        guard settings.isConfigured else {
            aiError = "请先在「我的 → LLM 设置」填入 API Key"
            return
        }
        aiLoading = true
        aiError = nil
        let client = ChatCompletionsClient(settings: settings)
        let sys = ChatMessage(role: "system", content:
            "你是英语学习助手。针对用户给出的英文短语（结合所在句子语境），用简洁中文输出：" +
            "① 中文翻译 ② 一句用法/语义解释。只输出中文，控制在 2-4 行，不要寒暄，不要重复英文原文。")
        let usr = ChatMessage(role: "user", content: "句子语境：\(cue.text)\n要查询的短语：\(phraseToSave)")
        do {
            let out = try await client.chat([sys, usr]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { note = out }
        } catch {
            aiError = (error as? LocalizedError)?.errorDescription ?? "AI 查询失败"
        }
        aiLoading = false
    }

    private func save() {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = cue.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = PendingPhrase(
            id: UUID(),
            entryId: entryId,
            videoTitle: videoTitle,
            youtubeId: youtubeId,
            phraseRaw: phraseToSave,
            contextSentence: cue.text,
            meaningZh: translation.isEmpty ? nil : translation,
            usageNote: trimmedNote.isEmpty ? nil : trimmedNote,
            timestampSec: cue.time,
            collectedAt: Date().timeIntervalSince1970
        )
        PendingPhraseStore.shared.add(pending)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
