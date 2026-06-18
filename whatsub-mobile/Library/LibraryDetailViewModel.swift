import Foundation
import SwiftUI

@MainActor
final class LibraryDetailViewModel: ObservableObject {
    @Published var entry: LibraryEntryDetail?
    @Published var loading = true
    @Published var errorMessage: String?
    @Published var currentIndex: Int?
    @Published var seek: SeekRequest?

    // Popup for a tapped highlight.
    @Published var popupWord: String?
    @Published var popupNote: String?
    @Published var popupTranslation: String?
    @Published var showPopup = false

    // MARK: - Subtitle editor state (2026-06-18)
    /// Toggles the 字幕 tab between read-only (CueRow) and edit-mode
    /// (CueRowEditing). When entering, we snapshot the server cues into
    /// `draftCues`; the read-only render still pulls from `entry` so the
    /// user can compare before-vs-after without losing context.
    @Published var editMode: Bool = false
    /// Working copy of the cue list while editing. Changes here don't
    /// touch `entry` until the user saves; cancel just drops these.
    @Published var draftCues: [Cue] = []
    /// True once any draftCues change has been made — drives the save
    /// button enable state + the "保存改动?" alert on navigation away.
    @Published var dirty: Bool = false
    @Published var saving: Bool = false
    @Published var saveError: String?

    private var cues: [Cue] { entry?.analysisJson.subtitles ?? [] }

    /// The cue at the current playhead (for the on-video caption overlay).
    var currentCue: Cue? {
        guard let idx = currentIndex, cues.indices.contains(idx) else { return nil }
        return cues[idx]
    }

    func load(id: String, token: String) async {
        loading = true; errorMessage = nil
        do {
            entry = try await WhatsubAPI.shared.libraryEntry(id: id, token: token)
        } catch APIError.unauthorized {
            errorMessage = "登录已过期，请到「我的」重新登录"
        } catch let e as APIError {
            errorMessage = e.chinese
        } catch {
            errorMessage = "加载失败"
        }
        loading = false
    }

    /// Called by the player bridge ~4x/sec. Updates currentIndex when the
    /// playhead crosses into a new cue.
    func onPlayerTime(_ sec: Double) {
        let cs = cues
        guard !cs.isEmpty else { return }
        let idx = cs.lastIndex(where: { $0.time <= sec + 0.05 })
        if idx != currentIndex { currentIndex = idx }
    }

    func seekTo(_ cue: Cue) {
        seek = SeekRequest(seconds: cue.time, nonce: UUID())
    }

    /// Seek by raw second (used by EntryCollectionsList — corpus phrases
    /// store timestampSec, not full Cue references).
    func seekTo(seconds: Double) {
        seek = SeekRequest(seconds: seconds, nonce: UUID())
    }

    // MARK: - Subtitle editor actions

    func startEditing() {
        guard let e = entry else { return }
        draftCues = e.analysisJson.subtitles
        dirty = false
        saveError = nil
        editMode = true
    }

    func cancelEditing() {
        draftCues = []
        dirty = false
        saveError = nil
        editMode = false
    }

    /// Update one cue's English text. If the cue had AI-marked highlight
    /// words / notes / translations, we clear them — the original phrases
    /// almost certainly no longer appear character-for-character after a
    /// text edit (the highlight matcher is substring-based). Better to
    /// drop them than to silently render stale highlights. A 「重新分析」
    /// button (deferred to P2) will let users re-run the LLM per cue.
    func updateCueText(at index: Int, text: String) {
        guard draftCues.indices.contains(index) else { return }
        var c = draftCues[index]
        guard c.text != text else { return }
        c.text = text
        if !c.highlightWords.isEmpty {
            c.highlightWords = []
            c.keyNotes = [:]
            c.highlightTranslations = [:]
            c.isKeyPoint = false
        }
        draftCues[index] = c
        dirty = true
    }

    func updateCueTranslation(at index: Int, translation: String) {
        guard draftCues.indices.contains(index) else { return }
        var c = draftCues[index]
        guard c.translation != translation else { return }
        c.translation = translation
        draftCues[index] = c
        dirty = true
    }

    /// Delete a cue from the draft. If it was the currently-playing cue,
    /// auto-advance to the next remaining one so the on-video caption
    /// overlay doesn't go briefly blank or freeze on a no-longer-existent
    /// cue index.
    func deleteCue(at index: Int) {
        guard draftCues.indices.contains(index) else { return }
        draftCues.remove(at: index)
        dirty = true
        if let cur = currentIndex {
            if cur == index {
                // Deleted the currently-playing one — seek to whatever's now
                // at this index (the original next cue), or the last cue if
                // we deleted from the tail.
                let nextIdx = min(index, draftCues.count - 1)
                if nextIdx >= 0 { seek = SeekRequest(seconds: draftCues[nextIdx].time, nonce: UUID()) }
            } else if cur > index {
                // Indices above the deletion shifted down by 1; keep currentIndex
                // pointing at the same logical cue.
                currentIndex = cur - 1
            }
        }
    }

    /// Save draft to server. Sorts by `time` (P2's merge/split could
    /// produce out-of-order entries), regenerates the SRT, POSTs to the
    /// new `/sync/:id/cues` endpoint. On success, replace `entry` with
    /// the updated analysisJson + leave edit mode. On failure, stay in
    /// edit mode and surface saveError so the user can retry or cancel.
    func saveEdits(token: String) async {
        guard let e = entry else { return }
        let sorted = draftCues.sorted { $0.time < $1.time }
        let newAnalysis = AnalysisJson.assembled(subtitles: sorted, keyPhrases: e.analysisJson.keyPhrases)
        let srt = SRTGenerator.generate(from: sorted)
        saving = true; saveError = nil
        do {
            try await WhatsubAPI.shared.updateLibraryEntryCues(
                entryId: e.id,
                analysis: newAnalysis,
                transcriptSrt: srt,
                token: token
            )
            // Apply to local entry so the rest of the view sees the edits.
            // LibraryEntryDetail is a struct with `let` fields — we have to
            // rebuild it. Cheap: it's a small value type.
            entry = LibraryEntryDetail(
                id: e.id,
                youtubeId: e.youtubeId,
                title: e.title,
                durationSec: e.durationSec,
                transcriptSrt: srt,
                analysisJson: newAnalysis,
                videoUrl: e.videoUrl,
                audioUrl: e.audioUrl
            )
            cancelEditing()
        } catch APIError.unauthorized {
            saveError = "登录已过期，请到「我的」重新登录"
        } catch let err as APIError {
            saveError = err.chinese
        } catch {
            saveError = "保存失败，请重试"
        }
        saving = false
    }

    func showHighlight(word: String, note: String?, translation: String?) {
        popupWord = word; popupNote = note; popupTranslation = translation; showPopup = true
    }
}
