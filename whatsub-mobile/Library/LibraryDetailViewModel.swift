import Foundation
import SwiftUI

enum DesktopReplacementState: Equatable {
    case idle
    case sending
    case queued(desktopOffline: Bool)
    case failed(String)
}

enum DesktopReplacementToolbarIndicator: Equatable {
    case none
    case progress
    case failure
}

enum DesktopReplacementToolbarPresentation {
    static func indicator(
        state: DesktopReplacementState,
        activeStatus: DesktopReplacementActiveStatus?
    ) -> DesktopReplacementToolbarIndicator {
        if activeStatus != nil { return .progress }
        switch state {
        case .sending, .queued:
            return .progress
        case .failed:
            return .failure
        case .idle:
            return .none
        }
    }
}

@MainActor
final class LibraryDetailViewModel: ObservableObject {
    @Published var entry: LibraryEntryDetail?
    @Published var loading = true
    @Published var errorMessage: String?
    @Published var currentIndex: Int?
    @Published var seek: SeekRequest?
    @Published var desktopReplacementState: DesktopReplacementState = .idle
    @Published var activeReplacementStatus: DesktopReplacementActiveStatus?
    @Published private(set) var displayedCues: [Cue] = []
    @Published private(set) var managedProgress: ManagedAnalysisProgressState?
    @Published var managedProgressError: String?
    @Published var managedResuming = false
    @Published private(set) var managedFinalSyncPending = false

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
    /// Set to the draft index currently being re-analyzed via the LLM so the
    /// row UI can show a spinner. nil = idle.
    @Published var analyzingCueIndex: Int?

    private let replacementAPI: any LibraryDesktopReplacementAPI
    private let managedAPI: any ManagedAnalysisClientProtocol
    private var replacementStatusTask: Task<Void, Never>?
    private var managedProgressTask: Task<Void, Never>?
    private var progressiveOverlay: ProgressiveAnalysisOverlay?
    private var managedBatchCursor = -1
    private var managedPollFailures = 0
    private var loadRevision = 0
    private var cues: [Cue] { displayedCues }

    init(
        api: any LibraryDesktopReplacementAPI = WhatsubAPI.shared,
        managedAPI: any ManagedAnalysisClientProtocol = WhatsubAPI.shared
    ) {
        replacementAPI = api
        self.managedAPI = managedAPI
    }

    /// The cue at the current playhead (for the on-video caption overlay).
    var currentCue: Cue? {
        guard let idx = currentIndex, cues.indices.contains(idx) else { return nil }
        return cues[idx]
    }

    func isWaitingForAI(_ cue: Cue) -> Bool {
        guard managedProgress?.status != .completed else { return false }
        return managedProgress != nil
            && progressiveOverlay?.resolvedIndexes.contains(cue.index) != true
    }

    var managedEditingBlocked: Bool {
        managedFinalSyncPending || managedProgress?.blocksEditing == true
    }

    var managedBannerLabel: String? {
        if managedFinalSyncPending { return "AI 解析完成 · 正在同步最终结果" }
        return managedProgress?.label
    }

    func load(id: String, token: String) async {
        loadRevision += 1
        let revision = loadRevision
        replacementStatusTask?.cancel()
        loading = true; errorMessage = nil
        do {
            let fetchedEntry = try await replacementAPI.libraryEntry(id: id, token: token)
            guard revision == loadRevision else { return }

            // Queue state is supplemental. Publish the playable detail and end
            // first-paint loading before starting its best-effort queue read.
            entry = fetchedEntry
            displayedCues = fetchedEntry.analysisJson.subtitles
            progressiveOverlay = ProgressiveAnalysisOverlay(baseline: displayedCues)
            managedBatchCursor = -1
            managedProgress = nil
            managedFinalSyncPending = false
            managedProgressError = nil
            loading = false
            replacementStatusTask = Task { [weak self] in
                await self?.refreshDesktopReplacementStatus(
                    token: token,
                    expectedEntryID: fetchedEntry.id
                )
            }
            return
        } catch APIError.unauthorized {
            guard revision == loadRevision else { return }
            errorMessage = "登录已过期，请到「我的」重新登录"
        } catch let e as APIError {
            guard revision == loadRevision else { return }
            errorMessage = e.chinese
        } catch {
            guard revision == loadRevision else { return }
            errorMessage = "加载失败"
        }
        if revision == loadRevision { loading = false }
    }

    func startManagedProgress(token: String) {
        managedProgressTask?.cancel()
        managedProgressTask = Task { [weak self] in
            await self?.runManagedProgress(token: token)
        }
    }

    func stopManagedProgress() {
        managedProgressTask?.cancel()
        managedProgressTask = nil
    }

    /// Discovers a job by its deterministic result-entry link. This makes the
    /// progressive state recoverable after relaunch and on another device.
    func discoverManagedAnalysis(token: String) async {
        guard let entry else { return }
        do {
            let jobs = try await managedAPI.jobs(token: token)
            guard !Task.isCancelled else { return }
            guard let job = jobs
                .filter({ $0.resultEntryId == entry.id })
                .max(by: { $0.updatedAt < $1.updatedAt }) else {
                managedProgress = nil
                return
            }
            managedProgress = ManagedAnalysisProgressState(job: job)
            progressiveOverlay = ProgressiveAnalysisOverlay(baseline: entry.analysisJson.subtitles)
            displayedCues = entry.analysisJson.subtitles
            managedBatchCursor = -1
            managedPollFailures = 0
            if job.status == .completed {
                managedFinalSyncPending = !(await reloadFinalEntry(id: entry.id, token: token))
            } else {
                do {
                    try await pollManagedAnalysisOnce(token: token)
                } catch is CancellationError {
                    return
                } catch {
                    managedPollFailures = 1
                    managedProgressError = "进度暂时无法更新，正在重试"
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // Supplemental progress must never hide the playable English entry.
        }
    }

    func pollManagedAnalysisOnce(token: String) async throws {
        guard let progress = managedProgress, let entry else { return }
        let page = try await managedAPI.results(
            id: progress.jobID,
            afterBatch: managedBatchCursor,
            token: token
        )
        try Task.checkCancellation()
        guard page.entryId == entry.id else { return }
        progressiveOverlay?.merge(page.batches)
        if let progressiveOverlay {
            displayedCues = progressiveOverlay.displayedCues(from: entry.analysisJson.subtitles)
        }
        managedBatchCursor = max(managedBatchCursor, page.nextBatchCursor)
        managedProgress = ManagedAnalysisProgressState(
            jobID: page.jobId,
            status: page.status,
            completedCues: page.completedCues,
            totalCues: page.totalCues,
            errorCode: page.errorCode
        )
        managedPollFailures = 0
        managedProgressError = nil
        if page.status == .completed {
            managedFinalSyncPending = !(await reloadFinalEntry(id: entry.id, token: token))
        }
    }

    func resumeManagedAnalysis(token: String) async {
        guard let jobID = managedProgress?.jobID else { return }
        managedResuming = true
        managedProgressError = nil
        defer { managedResuming = false }
        do {
            let job = try await managedAPI.resume(id: jobID, token: token)
            managedProgress = ManagedAnalysisProgressState(job: job)
            managedFinalSyncPending = false
            managedPollFailures = 0
            startManagedProgress(token: token)
        } catch {
            managedProgressError = "暂时无法继续解析，请稍后重试"
        }
    }

    private func runManagedProgress(token: String) async {
        await discoverManagedAnalysis(token: token)
        while !Task.isCancelled, let progress = managedProgress,
              progress.isPolling || managedFinalSyncPending {
            let delay = managedFinalSyncPending ? 4 : (ManagedAnalysisPollPolicy.delay(
                status: progress.status,
                failureCount: managedPollFailures
            ) ?? 5)
            let jitter = Double.random(in: 0...0.35)
            do {
                try await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
                try Task.checkCancellation()
                try await pollManagedAnalysisOnce(token: token)
            } catch is CancellationError {
                return
            } catch {
                managedPollFailures += 1
                managedProgressError = "进度暂时无法更新，正在重试"
            }
        }
    }

    private func reloadFinalEntry(id: String, token: String) async -> Bool {
        do {
            let finalEntry = try await replacementAPI.libraryEntry(id: id, token: token)
            guard !Task.isCancelled, entry?.id == id else { return false }
            entry = finalEntry
            displayedCues = finalEntry.analysisJson.subtitles
            progressiveOverlay = nil
            managedFinalSyncPending = false
            managedProgressError = nil
            return true
        } catch {
            // Keep the fully merged durable batches visible until a later reload.
            managedProgressError = "解析已完成，最终结果稍后自动同步"
            return false
        }
    }

    /// Reads the existing shared import queue once on detail load/refresh. The
    /// unfiltered GET does not touch desktop presence and adds no polling loop.
    func refreshDesktopReplacementStatus(
        token: String,
        expectedEntryID: String? = nil
    ) async {
        guard let entry, entry.needsDesktopDownload else {
            activeReplacementStatus = nil
            desktopReplacementState = .idle
            return
        }
        guard expectedEntryID == nil || expectedEntryID == entry.id else { return }
        do {
            let response = try await replacementAPI.listImportQueue(token: token)
            guard !Task.isCancelled, self.entry?.id == entry.id else { return }
            activeReplacementStatus = DesktopReplacementQueue.activeStatus(
                in: response.items,
                targetLibraryEntryId: entry.id
            )
            if activeReplacementStatus != nil {
                desktopReplacementState = .queued(
                    desktopOffline: DesktopPresence.isOffline(
                        secondsAgo: response.desktopSeenSecondsAgo
                    )
                )
            } else if desktopReplacementState != .sending {
                desktopReplacementState = .idle
            }
        } catch {
            // Queue status is supplemental. Keep the playable detail usable and
            // let the enqueue endpoint's atomic duplicate handling remain the
            // final authority if this best-effort read fails.
        }
    }

    /// Human-approved duration precheck runs before the enqueue call. Unknown
    /// duration/limit values intentionally pass through to backend + desktop
    /// final validation.
    func enqueueReplacement(
        maxVideoSeconds: Int?,
        token: String,
        email: String?
    ) async {
        guard let entry,
              entry.needsDesktopDownload,
              let url = entry.canonicalYouTubeURL else { return }
        guard activeReplacementStatus == nil else { return }

        if let message = DesktopReplacementDurationPolicy.blockingMessage(
            durationSec: entry.durationSec,
            maxVideoSeconds: maxVideoSeconds
        ) {
            desktopReplacementState = .failed(message)
            return
        }

        desktopReplacementState = .sending
        do {
            let response = try await replacementAPI.enqueueReplacement(
                url: url,
                targetLibraryEntryId: entry.id,
                token: token
            )
            let offline = DesktopPresence.isOffline(secondsAgo: response.desktopSeenSecondsAgo)
            activeReplacementStatus = response.status == "processing" ? .processing : .pending

            // Reuse the aggregate import-queue Live Activity. The backend also
            // pushes queue state; this local seed makes progress visible in the
            // same tick as the detail confirmation.
            if #available(iOS 16.2, *), let email {
                let initial = ImportActivityAttributes.ContentState(
                    inProgress: 1,
                    completed: 0,
                    failed: 0,
                    recentTitle: entry.title
                )
                await LiveActivityCoordinator.shared.ensureActivity(
                    forUserEmail: email,
                    initialState: initial
                )
            }

            desktopReplacementState = .queued(desktopOffline: offline)
        } catch let error as APIError {
            desktopReplacementState = .failed(error.chinese)
        } catch {
            desktopReplacementState = .failed(error.localizedDescription)
        }
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
        guard !managedEditingBlocked else { return }
        draftCues = displayedCues.isEmpty ? e.analysisJson.subtitles : displayedCues
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
                sourceUrl: e.sourceUrl,
                title: e.title,
                durationSec: e.durationSec,
                transcriptSrt: srt,
                analysisJson: newAnalysis,
                videoUrl: e.videoUrl,
                audioUrl: e.audioUrl
            )
            displayedCues = sorted
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

    /// Merge a cue with the one BEFORE it (drops the boundary between them).
    /// `cue[i-1].text + " " + cue[i].text`; time span becomes [prev.time,
    /// curr.endTime]. AI highlights are cleared on the merged result — the
    /// joined text needs re-analysis to mark phrases that span the boundary.
    /// No-op for the first cue (nothing to merge into).
    func mergeCueWithPrevious(at index: Int) {
        guard draftCues.indices.contains(index), index > 0 else { return }
        let prev = draftCues[index - 1]
        let curr = draftCues[index]
        let mergedText = [prev.text, curr.text].filter { !$0.isEmpty }.joined(separator: " ")
        let mergedTranslation = [prev.translation, curr.translation]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let merged = Cue(
            index: prev.index,
            time: prev.time,
            endTime: curr.endTime,
            text: mergedText,
            translation: mergedTranslation
        )
        var mergedVar = merged
        // Clear AI markers — the combined text has different positional
        // semantics, so any preserved highlightWords would be misleading.
        mergedVar.highlightWords = []
        mergedVar.keyNotes = [:]
        mergedVar.highlightTranslations = [:]
        mergedVar.isKeyPoint = false
        draftCues[index - 1] = mergedVar
        draftCues.remove(at: index)
        dirty = true
        // Currently-playing index update — same logic as deleteCue: if we
        // collapsed across the current index, point at the merged row.
        if let cur = currentIndex {
            if cur == index || cur == index - 1 {
                currentIndex = index - 1
            } else if cur > index {
                currentIndex = cur - 1
            }
        }
    }

    /// Split one cue into two by finding a space near the text midpoint and
    /// halving the time span. Translation halves at its char midpoint (no
    /// reliable grammar boundary detector for Chinese in this codebase).
    /// AI highlights drop — neither half inherits them.
    func splitCue(at index: Int) {
        guard draftCues.indices.contains(index) else { return }
        let c = draftCues[index]
        let (firstText, secondText) = Self.splitEnglish(c.text)
        let (firstZh, secondZh) = Self.splitChinese(c.translation)
        let midTime = (c.time + c.endTime) / 2.0
        let first = Cue(index: c.index,
                        time: c.time, endTime: midTime,
                        text: firstText, translation: firstZh)
        // Use a fresh non-collision index — actual index will be re-numbered
        // on next decode, but UI keys (`id == index`) need uniqueness in the
        // ForEach for this session. Use a value above the existing max.
        let nextIndex = (draftCues.map { $0.index }.max() ?? c.index) + 1
        let second = Cue(index: nextIndex,
                         time: midTime, endTime: c.endTime,
                         text: secondText, translation: secondZh)
        draftCues[index] = first
        draftCues.insert(second, at: index + 1)
        dirty = true
        if let cur = currentIndex, cur > index { currentIndex = cur + 1 }
    }

    /// Re-run the LLM analysis for ONE cue and copy back its highlightWords /
    /// keyNotes / highlightTranslations / isKeyPoint. Used after a text edit
    /// (which auto-clears those fields) to refresh the AI markers without
    /// re-running the full transcript analysis. ~1 LLM call, ~$0.005-ish at
    /// current DeepSeek pricing — surfaced via per-row context menu so users
    /// only pay when they explicitly ask.
    func reanalyzeCue(at index: Int) async {
        guard draftCues.indices.contains(index) else { return }
        let settings = LlmSettingsStore.load()
        guard settings.isConfigured else {
            saveError = "请先配置 LLM（我的 → LLM 设置）"
            return
        }
        analyzingCueIndex = index
        defer { analyzingCueIndex = nil }
        let target = draftCues[index]
        let client = ChatCompletionsClient(settings: settings)
        do {
            let raw = try await client.chat([
                ChatMessage(role: "system", content: AnalysisPrompts.system),
                ChatMessage(role: "user", content: AnalysisPrompts.userPrompt([target])),
            ])
            // Run the raw response through JsonLineParser → AnalysisEngine.parseCue,
            // mirroring the streaming pipeline's parsing semantics. Single-cue
            // reanalyze stays non-stream because the output is one short
            // line — streaming would be overkill.
            let parser = JsonLineParser()
            var parsed: [Cue] = []
            parser.feed(raw.hasSuffix("\n") ? raw : raw + "\n") { obj in
                if let cue = AnalysisEngine.parseCue(obj) { parsed.append(cue) }
            }
            parser.flush { obj in
                if let cue = AnalysisEngine.parseCue(obj) { parsed.append(cue) }
            }
            guard let updated = parsed.first else {
                saveError = "AI 返回为空"
                return
            }
            // Splice back ONLY the LLM-derived fields. Keep our timestamps +
            // text (LLM might have corrected typos we wanted preserved).
            var c = draftCues[index]
            c.translation = updated.translation.isEmpty ? c.translation : updated.translation
            c.isKeyPoint = updated.isKeyPoint
            c.highlightWords = updated.highlightWords
            c.keyNotes = updated.keyNotes
            c.highlightTranslations = updated.highlightTranslations
            draftCues[index] = c
            dirty = true
        } catch {
            saveError = "重新分析失败：\(error.localizedDescription)"
        }
    }

    /// Split English text at the space nearest the middle. Falls back to
    /// raw mid-char split if there's no space (single long word, rare).
    private static func splitEnglish(_ text: String) -> (String, String) {
        guard !text.isEmpty else { return ("", "") }
        let chars = Array(text)
        let mid = chars.count / 2
        var bestSpace = -1
        var bestDist = Int.max
        for i in chars.indices where chars[i] == " " {
            let d = abs(i - mid)
            if d < bestDist { bestDist = d; bestSpace = i }
        }
        if bestSpace > 0 {
            let prefix = String(chars[..<bestSpace])
            let suffix = String(chars[(bestSpace + 1)...])
                .trimmingCharacters(in: .whitespaces)
            return (prefix, suffix)
        }
        return (String(chars[..<mid]), String(chars[mid...]))
    }

    /// Split Chinese at the character midpoint. No grammar boundary detection;
    /// users can fine-tune the halves after the split via the row TextFields.
    private static func splitChinese(_ text: String) -> (String, String) {
        guard !text.isEmpty else { return ("", "") }
        let chars = Array(text)
        let mid = chars.count / 2
        return (String(chars[..<mid]), String(chars[mid...]))
    }

    func showHighlight(word: String, note: String?, translation: String?) {
        popupWord = word; popupNote = note; popupTranslation = translation; showPopup = true
    }
}
