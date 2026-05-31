import SwiftUI

/// Shown as a sheet when the user long-presses a chat bubble and taps
/// "显示中文". Translates via MyMemory by default; "用 AI 重译" button calls
/// the LLM for a better-quality translation.
struct BubbleTranslationView: View {
    let original: String

    @State private var translation: String = ""
    @State private var translatedVia: String = ""    // "MyMemory" or "AI"
    @State private var loading: Bool = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(title: "原文") {
                        Text(original)
                            .font(.system(size: 16))
                            .foregroundStyle(.whatsubInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubBgElev))
                    }

                    section(title: translatedVia.isEmpty ? "翻译" : "翻译 (\(translatedVia))") {
                        if loading {
                            HStack(spacing: 8) {
                                ProgressView().tint(.whatsubAccent)
                                Text("翻译中…").font(.subheadline).foregroundStyle(.whatsubInkMuted)
                            }
                            .padding(12)
                        } else if let err = errorMessage {
                            Text(err)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.1)))
                        } else if !translation.isEmpty {
                            Text(translation)
                                .font(.system(size: 16))
                                .foregroundStyle(.whatsubInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.whatsubAccent.opacity(0.12)))
                        }
                    }

                    if !translation.isEmpty && !loading {
                        Button {
                            Task { await retranslateViaLLM() }
                        } label: {
                            Label("用 AI 重译（更准确）", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.whatsubAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.whatsubAccent.opacity(0.5), lineWidth: 1.2))
                        }
                        .disabled(translatedVia == "AI")    // already AI-translated
                    }
                }
                .padding(20)
            }
            .background(Color.whatsubBg.ignoresSafeArea())
            .navigationTitle("翻译")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            await translateFirstTime()
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.whatsubInkFaint)
            content()
        }
    }

    private func translateFirstTime() async {
        loading = true
        errorMessage = nil
        do {
            translation = try await BubbleTranslator.translate(original, provider: .mymemory)
            translatedVia = "MyMemory"
        } catch {
            // Fall back to LLM silently on MyMemory failure (rate limit / network).
            do {
                translation = try await BubbleTranslator.translate(original, provider: .llm)
                translatedVia = "AI"
            } catch let llmError {
                errorMessage = (llmError as? LocalizedError)?.errorDescription ?? "翻译失败"
            }
        }
        loading = false
    }

    private func retranslateViaLLM() async {
        loading = true
        errorMessage = nil
        do {
            translation = try await BubbleTranslator.translate(original, provider: .llm)
            translatedVia = "AI"
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "AI 重译失败"
        }
        loading = false
    }
}
