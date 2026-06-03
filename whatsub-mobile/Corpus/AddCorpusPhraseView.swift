import SwiftUI

/// Manual phrase-add form for the 我的 corpus tab. Submits to
/// POST /api/corpus/contribute. Lets the user fill phrase + context (required)
/// + optional meaning/usage/tags/source URL. Has "用 AI 自动填" buttons for
/// meaning and usage that call the user's BYOK LLM for one-shot translation.
struct AddCorpusPhraseView: View {
    let availableTags: [CorpusTag]
    let onSuccess: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var phraseRaw: String = ""
    @State private var contextSentence: String = ""
    @State private var meaningZh: String = ""
    @State private var usageNote: String = ""
    @State private var sourceURL: String = ""
    @State private var selectedTags: Set<String> = []
    @State private var submitting: Bool = false
    @State private var aiLoadingMeaning: Bool = false
    @State private var aiLoadingUsage: Bool = false
    @State private var errorMessage: String?

    private let manualPlaceholderURL = "https://whatsub.eversay.cc/mobile/manual"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("英文短语 *", text: $phraseRaw, axis: .vertical)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(1...2)
                    TextField("出处句子 *", text: $contextSentence, axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text("必填")
                } footer: {
                    Text("出处句子是单词卡和对话陪练「卡住救援」时显示的复习材料。")
                        .font(.caption2).foregroundStyle(.whatsubInkMuted)
                }

                Section("可选") {
                    HStack(alignment: .top) {
                        TextField("中文含义", text: $meaningZh, axis: .vertical)
                            .lineLimit(1...3)
                        Button { Task { await aiFillMeaning() } } label: {
                            if aiLoadingMeaning {
                                ProgressView().controlSize(.small).tint(.whatsubAccent)
                            } else {
                                Image(systemName: "sparkles").foregroundStyle(.whatsubAccent)
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(aiLoadingMeaning || phraseRaw.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    HStack(alignment: .top) {
                        TextField("用法笔记 (英文搭配/语境)", text: $usageNote, axis: .vertical)
                            .lineLimit(1...3)
                        Button { Task { await aiFillUsage() } } label: {
                            if aiLoadingUsage {
                                ProgressView().controlSize(.small).tint(.whatsubAccent)
                            } else {
                                Image(systemName: "sparkles").foregroundStyle(.whatsubAccent)
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(aiLoadingUsage || phraseRaw.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    TextField("来源链接 (可选)", text: $sourceURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if !availableTags.isEmpty {
                    Section("标签 (多选)") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(availableTags) { t in
                                    tagChip(t)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("添加短语")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("保存") { Task { await submit() } }
                            .disabled(!canSubmit)
                    }
                }
            }
        }
    }

    private var canSubmit: Bool {
        !phraseRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !contextSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func tagChip(_ t: CorpusTag) -> some View {
        let on = selectedTags.contains(t.tag)
        return Button {
            if on { selectedTags.remove(t.tag) } else { selectedTags.insert(t.tag) }
        } label: {
            Text(t.tag)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? Color.whatsubAccent.opacity(0.25) : Color.whatsubBgElev, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Color.whatsubAccent : .clear, lineWidth: 1))
                .foregroundStyle(on ? .whatsubAccent : .whatsubInkSoft)
        }
        .buttonStyle(.plain)
    }

    // ---- submit ----
    private func submit() async {
        guard let token = appState.session?.sessionToken else {
            errorMessage = "未登录"
            return
        }
        errorMessage = nil
        submitting = true
        // URL — if blank, use the manual-add placeholder so the server's
        // canonicalizeUrl accepts a valid http(s) URL.
        let url: String = {
            let trimmed = sourceURL.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return manualPlaceholderURL }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
            return "https://" + trimmed   // user typed a bare host
        }()
        do {
            _ = try await WhatsubAPI.shared.contributePhrase(
                phraseRaw: phraseRaw.trimmingCharacters(in: .whitespacesAndNewlines),
                contextSentence: contextSentence.trimmingCharacters(in: .whitespacesAndNewlines),
                source: .webpage(url: url),
                meaningZh: meaningZh.trimmingCharacters(in: .whitespacesAndNewlines),
                usageNote: usageNote.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: Array(selectedTags),
                token: token
            )
            submitting = false
            onSuccess()
            dismiss()
        } catch let e as APIError {
            errorMessage = e.chinese
            submitting = false
        } catch {
            errorMessage = "添加失败：\(error.localizedDescription)"
            submitting = false
        }
    }

    // ---- AI fill helpers ----
    private func aiFillMeaning() async {
        let settings = LlmSettingsStore.load()
        guard settings.isConfigured else {
            errorMessage = "请先在「我的 → LLM 设置」填入 API Key"
            return
        }
        aiLoadingMeaning = true
        let client = ChatCompletionsClient(settings: settings)
        let sys = ChatMessage(role: "system", content:
            "你是英语→中文短语翻译助手。给定一个英文短语和可选的上下文句子，输出最自然的中文含义。" +
            "只输出中文翻译，1-2 行，不要寒暄，不要英文原文重复。")
        let ctx = contextSentence.isEmpty ? "" : "\n上下文：\(contextSentence)"
        let usr = ChatMessage(role: "user", content: "短语：\(phraseRaw)\(ctx)")
        do {
            let out = try await client.chat([sys, usr]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { meaningZh = out }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "AI 翻译失败"
        }
        aiLoadingMeaning = false
    }

    private func aiFillUsage() async {
        let settings = LlmSettingsStore.load()
        guard settings.isConfigured else {
            errorMessage = "请先在「我的 → LLM 设置」填入 API Key"
            return
        }
        aiLoadingUsage = true
        let client = ChatCompletionsClient(settings: settings)
        let sys = ChatMessage(role: "system", content:
            "你是英语词汇笔记助手。给定一个英文短语和可选上下文，用一行中文写出它的常见搭配/语境/语序提醒。" +
            "只输出 1 行简洁笔记，不寒暄。")
        let ctx = contextSentence.isEmpty ? "" : "\n上下文：\(contextSentence)"
        let usr = ChatMessage(role: "user", content: "短语：\(phraseRaw)\(ctx)")
        do {
            let out = try await client.chat([sys, usr]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { usageNote = out }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "AI 笔记失败"
        }
        aiLoadingUsage = false
    }
}
