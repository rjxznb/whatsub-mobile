import Foundation

protocol LearningGuidePersisting {
    func updateLearningGuide(
        id: String,
        expectedFingerprint: String,
        guide: LearningGuideDraft,
        profile: VideoContextProfile,
        token: String
    ) async throws -> LearningGuideUpdateResponse
}

enum VideoLearningGuideServiceError: Error, Equatable, LocalizedError {
    case missingAnalysisFingerprint
    case incompleteSummary

    var errorDescription: String? {
        switch self {
        case .missingAnalysisFingerprint:
            return "视频解析版本还没准备好，请刷新后重试。"
        case .incompleteSummary:
            return "AI 返回的学习导览不完整，请重试。"
        }
    }
}

struct VideoLearningGuideService {
    typealias SummaryProvider = (
        _ entry: LibraryEntryDetail,
        _ settings: LlmSettings,
        _ token: String
    ) async throws -> AnalysisSummary

    private let api: any LearningGuidePersisting
    private let summaryProvider: SummaryProvider

    init(
        api: any LearningGuidePersisting = WhatsubAPI.shared,
        summaryProvider: @escaping SummaryProvider = VideoLearningGuideService.produceSummary
    ) {
        self.api = api
        self.summaryProvider = summaryProvider
    }

    func generate(
        entry: LibraryEntryDetail,
        settings: LlmSettings,
        token: String
    ) async throws -> LearningGuideUpdateResponse {
        let fingerprint = entry.analysisFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LibraryAnalysisFingerprint.compute(title: entry.title, cues: entry.analysisJson.subtitles)
            : entry.analysisFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)

        try Task.checkCancellation()
        let summary = try await summaryProvider(entry, settings, token)
        try Task.checkCancellation()
        guard let guide = summary.learningGuide,
              let profile = summary.contextProfile else {
            throw VideoLearningGuideServiceError.incompleteSummary
        }

        let response = try await api.updateLearningGuide(
            id: entry.id,
            expectedFingerprint: fingerprint,
            guide: guide,
            profile: profile,
            token: token
        )
        try Task.checkCancellation()
        return response
    }

    private static func produceSummary(
        entry: LibraryEntryDetail,
        settings: LlmSettings,
        token: String
    ) async throws -> AnalysisSummary {
        let messages = try AnalysisPrompts.boundedSummaryMessages(entry.analysisJson.subtitles)
        let client = ChatCompletionsClient(
            settings: settings,
            sessionTokenOverride: token
        )
        let raw = try await client.chat(messages)
        try Task.checkCancellation()
        return try VideoLearningParser.parseSummary(
            Data(raw.utf8),
            durationSec: entry.durationSec.map(Double.init),
            cues: entry.analysisJson.subtitles
        )
    }
}
