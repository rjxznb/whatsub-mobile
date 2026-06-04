import Foundation
import SwiftUI
import UIKit

/// State machine for the 拍照识别短语 review screen. Owns:
///   - the captured UIImage
///   - the OCR text (user-editable)
///   - the analyzer result (translation + phrases)
///   - the selection set (user's tap-to-include picks)
///   - the sync progress
///
/// 2026-06-04 (拍照识别短语).
@MainActor
final class PhotoReviewViewModel: ObservableObject {

    enum Phase: Equatable {
        /// Camera or gallery is up, no image yet OR we already moved on.
        case empty
        case ocring
        case ocred
        case analyzing
        case reviewing
        case syncing(progress: String)
        case done(addedCount: Int, failedCount: Int)
        case error(String)
    }

    @Published private(set) var phase: Phase = .empty

    /// The captured photo. Cleared when the user dismisses the sheet.
    @Published private(set) var image: UIImage?

    /// OCR full text — editable in the UI so the user can fix
    /// misreads before hitting "AI 提取".
    @Published var ocrText: String = ""

    /// Result of the most recent analyzer call.
    @Published private(set) var analysis: PhotoAnalysisResult?

    /// PhotoPhrase ids the user has selected for sync.
    @Published var selected: Set<UUID> = []

    /// Stable per-capture-session UUID. Used as `source.localPhotoId`
    /// so future "我的 → 按来源" views can group phrases by photo.
    private(set) var localPhotoId: String = UUID().uuidString

    private let analyzer: PhotoAnalyzer

    init(analyzer: PhotoAnalyzer = .live()) {
        self.analyzer = analyzer
    }

    // MARK: - lifecycle

    /// Called when the camera / gallery picker hands us an image.
    func setImage(_ img: UIImage) async {
        image = img
        // Reset downstream state for the new capture.
        ocrText = ""
        analysis = nil
        selected.removeAll()
        localPhotoId = UUID().uuidString
        phase = .ocring
        do {
            let result = try await PhotoOCR.recognize(img)
            ocrText = result.fullText
            phase = .ocred
        } catch {
            phase = .error("OCR 识别失败:\(error.localizedDescription)")
        }
    }

    /// User edited the OCR text — keep it. (Phase stays .ocred.)
    func editOCRText(_ new: String) {
        ocrText = new
    }

    /// Called by the "AI 提取重点短语" button.
    func analyze() async {
        guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .error("OCR 文本为空,先拍一张含英文的清楚图片")
            return
        }
        phase = .analyzing
        let result = await analyzer.analyze(ocrText: ocrText)
        switch result {
        case .success(let r):
            analysis = r
            // Pre-select nothing — user explicitly opts in.
            selected.removeAll()
            phase = .reviewing
        case .failure(let msg):
            phase = .error(msg)
        }
    }

    /// Toggle one phrase's selected state.
    func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) }
        else { selected.insert(id) }
    }

    var selectedCount: Int { selected.count }

    /// Phrases the user has ticked, in order of appearance.
    var selectedPhrases: [PhotoPhrase] {
        guard let phrases = analysis?.phrases else { return [] }
        return phrases.filter { selected.contains($0.id) }
    }

    // MARK: - sync

    /// POST each selected phrase to /api/corpus/contribute. Sequential
    /// (not parallel) so an early 413 quota / 401 stops the rest, and
    /// so the progress text reads naturally.
    func sync(token: String) async {
        let pool = selectedPhrases
        guard !pool.isEmpty else { return }
        var added = 0
        var failed = 0
        phase = .syncing(progress: "正在同步 0/\(pool.count)…")
        for (i, p) in pool.enumerated() {
            phase = .syncing(progress: "正在同步 \(i + 1)/\(pool.count)…")
            let title = Self.shortPhotoTitle(from: ocrText)
            let source = PhraseSource.photo(
                localPhotoId: localPhotoId,
                title: title
            )
            do {
                _ = try await WhatsubAPI.shared.contributePhrase(
                    phraseRaw: p.phrase,
                    contextSentence: p.contextSentence.isEmpty ? p.phrase : p.contextSentence,
                    source: source,
                    meaningZh: p.meaningZh,
                    usageNote: p.usageNote,
                    tags: [],
                    token: token
                )
                added += 1
            } catch let e as APIError {
                failed += 1
                if case .server(let code, _) = e, code == 413 {
                    // Quota hit — stop the batch.
                    break
                }
            } catch {
                failed += 1
            }
        }
        phase = .done(addedCount: added, failedCount: failed)
    }

    /// Take the OCR'd first 30 chars (single-line) as a friendly title
    /// for the corpus source row's `title` field. Useful for the
    /// future "按来源" grouping — gives the user something readable
    /// rather than a UUID.
    private static func shortPhotoTitle(from ocrText: String) -> String {
        let firstLine = ocrText
            .split(whereSeparator: { $0 == "\n" })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let snippet = firstLine.prefix(30)
        return snippet.isEmpty ? "照片识别" : String(snippet)
    }
}
