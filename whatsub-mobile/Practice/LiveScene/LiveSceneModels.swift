import Foundation

/// Value types for the 实景口语练习 flow. Kept in one file because the
/// pipeline is short (Vision → prompt LLM → record → grade LLM) and the
/// types are all small structs that read together — splitting them across
/// 4 files would optimise for nothing.

// MARK: - Stage 1: Vision output

/// One image-classifier label from `VNClassifyImageRequest`. Top-K of these
/// (plus the human/animal counts) describe what's in the photo to the LLM
/// that writes the speaking prompt.
struct SceneLabel: Equatable {
    let identifier: String      // "bicycle", "outdoor", "afternoon", …
    let confidence: Float       // 0..1
}

/// Distilled "what's in the photo" snapshot. Vision returns hundreds of
/// labels but most are noise; the prompt LLM only sees the trimmed
/// top-K + the counts we got from the dedicated detectors. Keeping the
/// LLM input tight makes its output less hallucinated.
struct SceneContext: Equatable {
    /// Top-K labels (after a confidence floor of 0.3 + uniqueness dedup),
    /// ordered by descending confidence.
    let labels: [SceneLabel]
    /// `VNDetectHumanRectanglesRequest` — number of visible people. Useful
    /// because Apple's classifier returns "person" but no count.
    let humanCount: Int
    /// `VNDetectAnimalRectanglesRequest` (cats + dogs in current iOS).
    let animalCount: Int

    /// Render as a Chinese summary for the LLM prompt context block.
    /// Example: "labels: outdoor, bicycle, wall, afternoon; 人物: 2; 动物: 0"
    var llmDescription: String {
        let labelList = labels.map(\.identifier).joined(separator: ", ")
        return "labels: \(labelList); 人物: \(humanCount); 动物: \(animalCount)"
    }
}

// MARK: - Stage 2: LLM-derived speaking prompt

/// The prompt the user is asked to describe. The LLM derives this from a
/// `SceneContext` (Vision labels) — it's the bridge between "what the
/// computer saw" and "what we ask the user to say".
struct SpeakingPrompt: Equatable {
    /// English speaking task, 1-2 sentences. The reader-facing primary
    /// text. Example: "Describe the bikes you see and what time of day
    /// it might be. Try to use 2-3 of the suggested phrases."
    let promptEn: String
    /// One-sentence Chinese hint shown beneath the English prompt for
    /// scaffolding. Example: "用 2-3 句英文描述这个场景,试着用上下面建议的短语。"
    /// Hidden by default in the UI now; revealed via the 提示 button's
    /// first click (build 2026-06-05+).
    let promptZh: String
    /// English reference answer pre-computed at prompt-derivation time
    /// (NOT post-grading). A 25-50 word native-style description of THIS
    /// scene that naturally uses the targetVocab. Two uses:
    ///   1. Revealed via the 提示 button's second click — progressive
    ///      scaffolding for users who don't know where to start.
    ///   2. Shown in the review screen as "参考答案".
    /// Pre-computing once (vs. asking the grader to also produce one)
    /// keeps the LLM cost at 2 calls per session (derive + grade)
    /// instead of 3.
    let sampleAnswer: String
    /// 3-5 English target phrases the LLM expects to surface naturally
    /// in a good answer. Used both as scaffolding (visible chips) AND
    /// as the verdict keys handed to the grader on the next round-trip.
    let targetVocab: [String]
    /// 1 = easy/A2, 2 = mid/B1, 3 = stretch/B2. Drives the ★ row + lets
    /// us tune downstream grading strictness later.
    let difficulty: Int
}

// MARK: - Stage 3: LLM grade

/// One vocab hit/miss inside a single grade. Mirrors the `<<<VERDICT>>>`
/// per-phrase shape QuickChat uses so we COULD wire this to
/// `ProductionProgressStore` if we wanted mastery tracking — v1 stays
/// sandboxed (no store writes) since these are LLM-generated vocab targets,
/// not user-curated phrases.
struct VocabHit: Equatable, Identifiable {
    var id: String { phrase }
    let phrase: String
    let attempted: Bool
    let correct: Bool
    /// Optional one-sentence Chinese feedback ("'leaning against' 是地道
    /// 搭配,'lean to' 不对"). Empty when correct.
    let note: String
}

/// LLM's grade of a single user attempt. The UI renders the score + feedback
/// + the per-vocab roll-up. The "参考答案" shown in review is
/// `prompt.sampleAnswer` (pre-computed at derivation time) — the grader
/// doesn't re-generate it, saving one LLM round-trip per session.
struct SceneGrade: Equatable {
    /// 1-5 overall score. The LLM is told to be encouraging but not
    /// dishonest — see `LiveScenePrompts.gradingSystemPrompt`.
    let score: Int
    /// 2-3 sentence Chinese feedback. What the user did well + what to
    /// improve. Avoids hedging fluff.
    let feedback: String
    /// Per-targetVocab roll-up. Length matches `SpeakingPrompt.targetVocab`
    /// — the LLM is told to emit one entry per target.
    let vocabHits: [VocabHit]
}

// MARK: - Outcome wrappers (NOT Swift's Result)

/// Outcome of the Vision step. We use a custom enum (instead of `throws`)
/// because the UI banner needs a Chinese error string, not an `Error`
/// instance. Same shape as `PhotoAnalyzer.AnalysisOutcome` and
/// `RoleplayScenarioClient.DerivationOutcome` — `Result<S, F>` requires
/// `F: Error` which `String` doesn't satisfy. CI catches this every time
/// we forget. See feedback_swift_result_string_compile.
enum SceneClassifyOutcome {
    case success(SceneContext)
    case failure(String)
}

/// Outcome of the prompt-derivation LLM call.
enum PromptDerivationOutcome {
    case success(SpeakingPrompt)
    case failure(String)
}

/// Outcome of the grading LLM call.
enum GradingOutcome {
    case success(SceneGrade)
    case failure(String)
}
