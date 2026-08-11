import Foundation
import SwiftUI

enum DeepGlossPhase: Equatable {
    case idle
    case preparingContext
    case loading
    case loaded
    case analysisChanged
    case fingerprintUnavailable
    case failed(RemoteFailure)
}

enum DeepGlossPreparationError: Error, Equatable, LocalizedError {
    case analysisChanged
    case fingerprintUnavailable
    case profileUnavailable
    case failed(RemoteFailure)

    var errorDescription: String? {
        switch self {
        case .analysisChanged:
            return "字幕解析已更新，请重试深度解读。"
        case .fingerprintUnavailable:
            return "视频解析版本还没准备好，请刷新后重试。"
        case .profileUnavailable:
            return "视频语境还没准备好，请重试。"
        case .failed(let failure):
            return failure.message
        }
    }
}

@MainActor
final class DeepGlossViewModel: ObservableObject {
    typealias Provider = (_ messages: [ChatMessage]) async throws -> String
    typealias EnsureProfile = () async throws -> WordGloss.SourceContext

    @Published private(set) var phase: DeepGlossPhase = .idle
    @Published private(set) var result: DeepGlossResult?

    private let cache: DeepGlossCache
    private let provider: Provider
    private var loadTask: Task<Void, Never>?
    private var loadTaskID: UUID?

    init(cache: DeepGlossCache = .shared, provider: @escaping Provider) {
        self.cache = cache
        self.provider = provider
    }

    convenience init(
        settings: LlmSettings,
        token: String,
        cache: DeepGlossCache = .shared
    ) {
        let client = ChatCompletionsClient(
            settings: settings,
            sessionTokenOverride: token
        )
        self.init(cache: cache) { messages in
            try await client.chat(messages)
        }
    }

    var canRetry: Bool {
        switch phase {
        case .analysisChanged, .fingerprintUnavailable, .failed:
            return true
        case .idle, .preparingContext, .loading, .loaded:
            return false
        }
    }

    func load(gloss: WordGloss, ensureProfile: EnsureProfile?) async {
        if let loadTask {
            await loadTask.value
            return
        }
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(gloss: gloss, ensureProfile: ensureProfile)
        }
        loadTaskID = taskID
        loadTask = task
        await task.value
        if loadTaskID == taskID {
            loadTask = nil
            loadTaskID = nil
        }
    }

    func cancel() {
        loadTask?.cancel()
    }

    private func performLoad(
        gloss: WordGloss,
        ensureProfile: EnsureProfile?
    ) async {
        result = nil
        do {
            guard var source = gloss.sourceContext else {
                throw DeepGlossPreparationError.profileUnavailable
            }
            if source.profile == nil {
                phase = .preparingContext
                guard let ensureProfile else {
                    throw DeepGlossPreparationError.profileUnavailable
                }
                source = try await ensureProfile()
                try Task.checkCancellation()
            }
            guard let profile = source.profile else {
                throw DeepGlossPreparationError.profileUnavailable
            }
            let fingerprint = source.analysisFingerprint
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fingerprint.isEmpty else {
                throw DeepGlossPreparationError.fingerprintUnavailable
            }
            guard source.cues.indices.contains(source.currentCueIndex) else {
                throw DeepGlossPreparationError.profileUnavailable
            }
            let cueAnchor = String(source.cues[source.currentCueIndex].index)
            if let cached = await cache.value(
                fingerprint: fingerprint,
                cueAnchor: cueAnchor,
                expression: gloss.word
            ) {
                try Task.checkCancellation()
                result = cached
                phase = .loaded
                return
            }

            phase = .loading
            let payload = DeepGlossPrompt.build(context: DeepGlossContext(
                title: source.title,
                profile: profile,
                expression: gloss.word,
                quickTranslation: gloss.translation,
                quickNote: gloss.note,
                cues: source.cues,
                currentCueIndex: source.currentCueIndex
            ))
            let raw = try await provider(payload.messages)
            try Task.checkCancellation()
            let parsed = try DeepGlossParser.parse(raw)
            try Task.checkCancellation()
            await cache.store(
                parsed,
                fingerprint: fingerprint,
                cueAnchor: cueAnchor,
                expression: gloss.word
            )
            try Task.checkCancellation()
            result = parsed
            phase = .loaded
        } catch is CancellationError {
            result = nil
            phase = .idle
        } catch DeepGlossPreparationError.analysisChanged {
            phase = .analysisChanged
        } catch DeepGlossPreparationError.fingerprintUnavailable {
            phase = .fingerprintUnavailable
        } catch DeepGlossPreparationError.failed(let failure) {
            phase = .failed(failure)
        } catch {
            if Task.isCancelled {
                result = nil
                phase = .idle
            } else {
                phase = .failed(RemoteFailure.from(error, fallback: "深度解读失败"))
            }
        }
    }
}
