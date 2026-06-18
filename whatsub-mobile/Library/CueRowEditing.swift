import SwiftUI

/// Edit-mode row for the 字幕 tab's subtitle list. Renders the cue's
/// English + Chinese as inline TextFields (axis: .vertical for multi-line
/// wrapping), with the timestamp shown but NOT editable — by design.
///
/// Why timestamps aren't editable: getting them right is hard (sub-frame
/// alignment matters), and the editor's primary use case is fixing typos
/// or deleting bad cues, not authoring new content from scratch. Users
/// who need timestamp adjustment can do it on the desktop client where
/// there's a real scrubber + waveform UI.
///
/// AI highlight markers (`isKeyPoint`, yellow underline, etc.) are NOT
/// shown in edit mode — once the user edits text, the original highlight
/// positions are likely stale, and ViewModel.updateCueText clears them.
/// The empty space those used to occupy collapses cleanly.
struct CueRowEditing: View {
    let index: Int
    let cue: Cue
    let canMergeUp: Bool
    let isAnalyzing: Bool
    let onTextChange: (String) -> Void
    let onTranslationChange: (String) -> Void
    let onMergeUp: () -> Void
    let onSplit: () -> Void
    let onReanalyze: () -> Void

    /// Local copies so TextField bindings have a stable @State to update —
    /// re-syncing from `cue` on appear means tapping a different row
    /// instantly reflects the right text. Two-way binding to the VM
    /// happens via the change handlers (called on every commit, which
    /// SwiftUI fires on every keystroke for TextField(text:)).
    @State private var englishDraft: String = ""
    @State private var chineseDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(mmss(cue.time))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.whatsubInkFaint)
                Text("→ \(mmss(cue.endTime))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.whatsubInkFaint)
                Spacer()
                if isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.whatsubAccent)
                }
            }
            TextField("英文", text: $englishDraft, axis: .vertical)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.whatsubInk)
                .textFieldStyle(.plain)
                .onChange(of: englishDraft) { newValue in onTextChange(newValue) }
            TextField("中文", text: $chineseDraft, axis: .vertical)
                .font(.system(size: 14))
                .foregroundStyle(.whatsubInkMuted)
                .textFieldStyle(.plain)
                .onChange(of: chineseDraft) { newValue in onTranslationChange(newValue) }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        // Long-press → contextMenu: merge / split / re-analyze. Lives at
        // row-level so the user can trigger from any spot in the row,
        // not just a tiny toolbar icon. Each item is hidden when
        // inappropriate (canMergeUp / isAnalyzing).
        .contextMenu {
            if canMergeUp {
                Button {
                    onMergeUp()
                } label: {
                    Label("合并到上一句", systemImage: "arrow.up.and.line.horizontal.and.arrow.down")
                }
            }
            Button {
                onSplit()
            } label: {
                Label("拆成两句", systemImage: "rectangle.split.2x1")
            }
            Button {
                onReanalyze()
            } label: {
                Label("AI 重新分析", systemImage: "sparkles")
            }
            .disabled(isAnalyzing)
        }
        .onAppear {
            englishDraft = cue.text
            chineseDraft = cue.translation
        }
        // Keep local draft in sync when the underlying cue mutates externally
        // (e.g., the ViewModel restored a value during a cancel). Without
        // this, a cancel-then-restart-edit shows the old typed text.
        .onChange(of: cue.text) { newValue in
            if newValue != englishDraft { englishDraft = newValue }
        }
        .onChange(of: cue.translation) { newValue in
            if newValue != chineseDraft { chineseDraft = newValue }
        }
    }

    private func mmss(_ sec: Double) -> String {
        let s = max(0, Int(sec))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
