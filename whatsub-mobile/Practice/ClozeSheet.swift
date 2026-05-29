import SwiftUI
import AVFoundation

/// 听抄 sheet (listening cloze game). Flow:
///   1. Auto-plays the cue once on appear (with a 🔁 to replay)
///   2. Shows the cue text with the target phrase blanked out as "___"
///   3. Renders 4 tile options (1 correct + 3 distractors) below
///   4. Tap a tile → green ✓ (correct) or red shake (wrong → tile fades out
///      and user picks again from the remaining)
///   5. On correct → reveal full cue with the answer highlighted + ZH translation
///      + "再来一句 / 完成"
///
/// Target selection prefers `cue.highlightWords` (the AI-tagged learning phrase
/// — that's literally the thing whatSub wants the user to learn). Falls back
/// to the longest non-stopword in the cue. Distractors come from other cues
/// in the same entry: similar-length phrases/words to keep difficulty fair.
struct ClozeSheet: View {
    /// All cues in this entry (ordered by time). The sheet picks distractors
    /// from neighbors AND uses the list to advance to "下一个 →" without
    /// requiring the user to close + long-press another cue.
    let allCues: [Cue]
    let videoURL: URL?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var audio: CueAudioPlayer
    /// The cue currently being practiced. Mutable so 下一个 can advance us
    /// without dismissing the sheet.
    @State private var currentCue: Cue
    @State private var target: String = ""
    @State private var options: [String] = []
    @State private var rejected: Set<String> = []
    @State private var solved = false
    @State private var shake = 0   // increments on wrong tap to trigger shake animation

    init(cue: Cue, allCues: [Cue], videoURL: URL?) {
        self.allCues = allCues
        self.videoURL = videoURL
        _currentCue = State(initialValue: cue)
        if let v = videoURL {
            _audio = StateObject(wrappedValue: CueAudioPlayer(videoURL: v))
        } else {
            _audio = StateObject(wrappedValue: CueAudioPlayer(videoURL: URL(string: "file:///dev/null")!))
        }
    }

    /// Position of the current cue in allCues (for hasNext + advance logic).
    /// Cue ids are synthesized at decode-time from array position so they're
    /// stable per-load; safe to compare by index.
    private var currentPos: Int? {
        allCues.firstIndex(where: { $0.index == currentCue.index })
    }
    private var hasNext: Bool {
        guard let pos = currentPos else { return false }
        return pos + 1 < allCues.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Replay button + hint
                    HStack {
                        Button {
                            audio.play(from: currentCue.time, to: currentCue.endTime)
                        } label: {
                            Label(audio.isPlaying ? "播放中…" : "听原文", systemImage: "play.circle.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.whatsubAccent)
                        .disabled(videoURL == nil)
                        Spacer()
                        // Position counter so the user knows progress through the
                        // entry (e.g., "12 / 38") — natural with 下一个 navigation.
                        if let pos = currentPos {
                            Text("\(pos + 1) / \(allCues.count)")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(.whatsubInkFaint)
                        }
                    }

                    blankedCueCard
                    if !solved { tiles } else { resultActions }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("听抄练习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { audio.stop(); dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task {
            buildPuzzle()
            // Auto-play once on appear — primes the listen-then-pick loop.
            if videoURL != nil {
                try? await Task.sleep(nanoseconds: 300_000_000) // let the sheet finish presenting
                audio.play(from: currentCue.time, to: currentCue.endTime)
            }
        }
        .onDisappear { audio.stop() }
    }

    // ---------------------------------------------------------------- cue card

    private var blankedCueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // English with the target blanked out (or revealed in green once solved).
            Text(renderedCue)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.whatsubInk)
            Text(currentCue.translation)
                .font(.system(size: 15))
                .foregroundStyle(.whatsubInkMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.whatsubBgElev))
    }

    /// Rendered cue: target replaced with `_____` (1 underscore per char, min 4)
    /// before solve; original text after solve with target highlighted via
    /// AttributedString (italic + accent).
    private var renderedCue: AttributedString {
        var attr = AttributedString(currentCue.text)
        guard !target.isEmpty,
              let r = attr.range(of: target, options: [.caseInsensitive])
        else { return attr }
        if solved {
            attr[r].foregroundColor = .green
            attr[r].font = .system(size: 20, weight: .bold)
        } else {
            // Replace the target characters with underscores of matching length
            // (preserves sentence width). Min 4 underscores so single-letter
            // targets are still visible.
            let placeholder = String(repeating: "_", count: max(4, target.count))
            attr.replaceSubrange(r, with: AttributedString(placeholder))
            if let pRange = attr.range(of: placeholder) {
                attr[pRange].foregroundColor = .whatsubAccent
                attr[pRange].font = .system(size: 20, weight: .bold)
            }
        }
        return attr
    }

    // -------------------------------------------------------------- tiles

    private var tiles: some View {
        VStack(spacing: 10) {
            ForEach(options, id: \.self) { opt in
                Button { tap(opt) } label: {
                    HStack {
                        Text(opt)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(rejected.contains(opt) ? .whatsubInkFaint : .whatsubInk)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(rejected.contains(opt) ? Color.red.opacity(0.08) : Color.whatsubBgElev)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(rejected.contains(opt) ? Color.red.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(rejected.contains(opt))
            }
        }
        .modifier(ShakeEffect(animatableData: CGFloat(shake)))
    }

    private var resultActions: some View {
        HStack(spacing: 10) {
            Button("再来一次") { resetForRetry() }
                .buttonStyle(.bordered).tint(.whatsubAccent)
            Spacer()
            if hasNext {
                // Primary action after solving — continue practice without
                // closing the sheet. 完成 is still available on the left.
                Button { advanceToNextCue() } label: {
                    Label("下一句", systemImage: "arrow.right.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(.whatsubAccent)
            } else {
                // Last cue in the entry — surface that the user finished, no
                // ambiguous "下一句" that would silently no-op.
                Text("已是最后一句").font(.caption).foregroundStyle(.whatsubInkFaint)
                Button("完成") { audio.stop(); dismiss() }
                    .buttonStyle(.borderedProminent).tint(.whatsubAccent)
            }
        }
    }

    // --------------------------------------------------------- game logic

    private func tap(_ choice: String) {
        if choice.lowercased() == target.lowercased() {
            solved = true
            SoundFX.correct()
        } else {
            rejected.insert(choice)
            withAnimation(.default) { shake += 1 }
        }
    }

    private func resetForRetry() {
        solved = false
        rejected = []
        buildPuzzle()
        // Auto-replay the original on retry so the user re-hears it.
        if videoURL != nil { audio.play(from: currentCue.time, to: currentCue.endTime) }
    }

    /// Move to the next cue in the entry. Resets puzzle state + auto-plays the
    /// new cue's audio. No-op (guarded by hasNext on the call site button) if
    /// we're already at the last cue.
    private func advanceToNextCue() {
        guard let pos = currentPos, pos + 1 < allCues.count else { return }
        audio.stop()
        currentCue = allCues[pos + 1]
        solved = false
        rejected = []
        buildPuzzle()
        if videoURL != nil { audio.play(from: currentCue.time, to: currentCue.endTime) }
    }

    /// Picks the target word/phrase + 3 distractors, shuffled into `options`.
    private func buildPuzzle() {
        target = pickTarget()
        var distractors = pickDistractors(target: target)
        // Pad with fallback common words if we couldn't find enough good distractors.
        while distractors.count < 3 {
            if let f = ClozeSheet.fallbackPool.randomElement(),
               !distractors.contains(f),
               f.lowercased() != target.lowercased() {
                distractors.append(f)
            } else if distractors.count < 3 {
                distractors.append("(none)")
                break
            }
        }
        options = ([target] + distractors).shuffled()
    }

    private func pickTarget() -> String {
        // Prefer the AI-tagged highlight phrases — that's what we want the user
        // to learn. Filter to phrases that actually appear in the cue text (case
        // sometimes drifts) and pick the longest.
        let highlights = currentCue.highlightWords
            .filter { currentCue.text.range(of: $0, options: .caseInsensitive) != nil }
            .sorted { $0.count > $1.count }
        if let h = highlights.first { return h }
        // Fallback: longest non-stopword in the cue.
        let words = currentCue.text.split(separator: " ", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }.filter { $0.count >= 4 && !ClozeSheet.stopwords.contains($0.lowercased()) }
        return words.max(by: { $0.count < $1.count }) ?? (currentCue.text.split(separator: " ").first.map(String.init) ?? "")
    }

    private func pickDistractors(target: String) -> [String] {
        // Pull candidates from sibling cues' highlightWords + long words. Filter
        // to similar length (±3 chars) for visual fairness. Deduplicate.
        let tLen = target.count
        var seen = Set<String>([target.lowercased()])
        var out: [String] = []
        // Excludes the current cue so the "obvious answer staring at you" can't
        // sneak in as a distractor.
        let candidates = allCues
            .filter { $0.index != currentCue.index }
            .flatMap { c -> [String] in
                let hl = c.highlightWords
                let words = c.text.split(separator: " ", omittingEmptySubsequences: true).map {
                    $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                }.filter { $0.count >= 3 && !ClozeSheet.stopwords.contains($0.lowercased()) }
                return hl + words
            }
            .shuffled()
        for cand in candidates {
            let lc = cand.lowercased()
            if seen.contains(lc) { continue }
            if abs(cand.count - tLen) > 4 { continue }
            seen.insert(lc)
            out.append(cand)
            if out.count >= 3 { break }
        }
        return out
    }

    // Common English stopwords excluded from auto-target + distractor selection.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were", "be",
        "been", "being", "have", "has", "had", "do", "does", "did", "will",
        "would", "should", "could", "may", "might", "must", "can", "this",
        "that", "these", "those", "i", "you", "he", "she", "it", "we", "they",
        "what", "which", "who", "whom", "where", "when", "why", "how", "all",
        "any", "both", "each", "few", "more", "most", "other", "some", "such",
        "no", "nor", "not", "only", "own", "same", "so", "than", "too", "very",
        "with", "from", "into", "onto", "of", "on", "in", "to", "for", "by",
        "at", "as", "if", "about", "above", "after", "again", "against",
        "below", "between", "down", "during", "out", "over", "under", "up",
    ]
    // Hard-coded fallback distractor pool — used only when the cue's pool is
    // too small to produce 3 plausible distractors (e.g., very short videos).
    private static let fallbackPool: [String] = [
        "people", "world", "money", "story", "morning", "moment", "really",
        "actually", "always", "sometimes", "however", "because", "important",
        "company", "country", "decision", "performance", "experience",
    ]
}

/// Trigger an in-place horizontal shake when `animatableData` changes — used
/// for the wrong-answer feedback on tiles.
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat = 0
    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = sin(animatableData * .pi * 6) * 6
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}
