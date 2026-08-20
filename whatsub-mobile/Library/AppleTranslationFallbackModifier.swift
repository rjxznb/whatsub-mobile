import SwiftUI
import Translation

@available(iOS 18.0, *)
private struct AppleTranslationFallbackModifier: ViewModifier {
    @ObservedObject var viewModel: LibraryDetailViewModel
    let token: String?
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onAppear { scheduleIfNeeded() }
            .onChange(of: viewModel.appleTranslationOperation?.id) { _ in
                scheduleIfNeeded()
            }
            .translationTask(configuration) { session in
                guard let operation = await viewModel.appleTranslationOperation else { return }
                guard let token else {
                    await viewModel.failAppleTranslation(operationID: operation.id)
                    return
                }
                let items = operation.requests
                await viewModel.beginAppleTranslation(operationID: operation.id)
                do {
                    let sourceByIndex = Dictionary(
                        uniqueKeysWithValues: items.map { ($0.cueIndex, $0.sourceText) }
                    )
                    // Keep each framework request bounded for long Pro videos;
                    // every response is checkpointed before the next arrives.
                    for start in stride(from: 0, to: items.count, by: 50) {
                        let batch = items[start..<min(start + 50, items.count)].map {
                            TranslationSession.Request(
                                sourceText: $0.sourceText,
                                clientIdentifier: String($0.cueIndex)
                            )
                        }
                        for try await response in session.translate(batch: batch) {
                            try Task.checkCancellation()
                            guard let identifier = response.clientIdentifier,
                                  let cueIndex = Int(identifier),
                                  let sourceText = sourceByIndex[cueIndex] else { continue }
                            let accepted = await viewModel.acceptAppleTranslation(
                                operationID: operation.id,
                                cueIndex: cueIndex,
                                sourceText: sourceText,
                                translation: response.targetText
                            )
                            guard accepted else { return }
                        }
                    }
                    try Task.checkCancellation()
                    await viewModel.finishAppleTranslation(
                        operationID: operation.id,
                        token: token
                    )
                } catch is CancellationError {
                    // SwiftUI cancels translationTask when the detail view goes
                    // away. Per-response checkpoints make the next visit resume.
                    await viewModel.pauseAppleTranslationForRetry(operationID: operation.id)
                } catch {
                    await viewModel.failAppleTranslation(operationID: operation.id)
                }
            }
    }

    private func scheduleIfNeeded() {
        guard viewModel.appleTranslationPhase.shouldRunTranslationTask,
              viewModel.appleTranslationOperation != nil else {
            configuration = nil
            return
        }
        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "zh-Hans")
            )
        } else {
            configuration?.invalidate()
        }
    }
}

extension View {
    @MainActor
    @ViewBuilder
    func appleTranslationFallback(
        viewModel: LibraryDetailViewModel,
        token: String?
    ) -> some View {
        if #available(iOS 18.0, *) {
            modifier(AppleTranslationFallbackModifier(viewModel: viewModel, token: token))
        } else {
            self
        }
    }
}
