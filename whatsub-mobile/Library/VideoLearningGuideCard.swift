import SwiftUI

struct VideoLearningGuidePresentation {
    struct Section: Equatable {
        let title: String
        let lines: [String]
    }

    let guide: LearningGuide

    var verdictText: String {
        switch guide.verdict {
        case .studyAll: return "很值得完整学习"
        case .selectSegments: return "建议挑选重点片段"
        case .extensiveListening: return "更适合泛听了解"
        case .limitedValue: return "学习价值有限"
        }
    }

    var cefrText: String { guide.cefrLevel.rawValue }

    var sections: [Section] {
        [
            Section(title: "30 秒概览", lines: [guide.overview]),
            Section(title: "内容提要", lines: guide.contentOutline),
            Section(title: "为什么值得学", lines: guide.learningReasons),
            Section(
                title: "适合谁学",
                lines: guide.recommendedFor + ["CEFR \(cefrText)：\(guide.cefrReason)"]
            ),
            Section(title: "文化与语境", lines: guide.cultureNotes),
            Section(title: "学习建议", lines: guide.studyTips),
            Section(
                title: "重点片段",
                lines: guide.topSegments.flatMap { segment in
                    [segment.title, segment.reason] + segment.focusExpressions
                }
            ),
        ]
    }

    var allVisibleText: String {
        ([verdictText, cefrText, guide.overview] + sections.flatMap(\.lines))
            .joined(separator: "\n")
    }
}

enum VideoLearningGuideAnalysisAvailability: Equatable {
    case available
    case waiting
    case resumeRequired

    static func make(status: ManagedAnalysisJobStatus?) -> Self {
        switch status {
        case .queued, .running:
            return .waiting
        case .pausedQuota, .failed, .cancelled:
            return .resumeRequired
        case .completed, nil:
            return .available
        }
    }
}

struct VideoLearningGuideCard: View {
    let guide: LearningGuide?
    let phase: VideoLearningGuidePhase
    let analysisAvailability: VideoLearningGuideAnalysisAvailability
    @Binding var isExpanded: Bool
    let onGenerate: () -> Void
    let onRetry: () -> Void
    let onResumeAnalysis: () -> Void
    let onSubscribe: () -> Void
    let onConfigureLLM: () -> Void
    let onSelectSegment: (RecommendedSegment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let guide {
                guideContent(guide)
            } else {
                missingGuideContent
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.whatsubBgElev)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.whatsubAccent.opacity(0.16), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func guideContent(_ guide: LearningGuide) -> some View {
        let presentation = VideoLearningGuidePresentation(guide: guide)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(presentation.verdictText)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.whatsubAccent)
                        Text(presentation.cefrText)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.whatsubInkSoft)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.whatsubBg, in: Capsule())
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.whatsubInkMuted)
                    }
                    Text(guide.overview)
                        .font(.subheadline)
                        .foregroundStyle(.whatsubInk)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent(guide, presentation: presentation)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func expandedContent(
        _ guide: LearningGuide,
        presentation: VideoLearningGuidePresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(presentation.sections.dropLast().enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }

            if !guide.topSegments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("重点片段")
                    ForEach(Array(guide.topSegments.enumerated()), id: \.offset) { _, segment in
                        Button { onSelectSegment(segment) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(timestamp(segment.startTime))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.whatsubAccent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(segment.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.whatsubInk)
                                    Text(segment.reason)
                                        .font(.footnote)
                                        .foregroundStyle(.whatsubInkSoft)
                                    if !segment.focusExpressions.isEmpty {
                                        Text(segment.focusExpressions.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.whatsubInkMuted)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(.whatsubAccent)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.whatsubBg, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sectionView(_ section: VideoLearningGuidePresentation.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(section.title)
            if section.lines.isEmpty {
                Text("暂无可靠信息")
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkMuted)
            } else {
                ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.whatsubInkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.whatsubInk)
    }

    @ViewBuilder
    private var missingGuideContent: some View {
        if analysisAvailability == .waiting {
            Label("解析完成后可生成", systemImage: "clock")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.whatsubInkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if analysisAvailability == .resumeRequired {
            VStack(alignment: .leading, spacing: 8) {
                Label("先继续完成 AI 解析，再生成视频学习导览。", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.whatsubInkSoft)
                Button("继续 AI 解析", action: onResumeAnalysis)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(.whatsubAccent)
            }
        } else {
            switch phase {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.whatsubAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在生成视频学习导览…")
                            .font(.subheadline.weight(.semibold))
                        Text("字幕和视频仍可继续使用")
                            .font(.caption)
                            .foregroundStyle(.whatsubInkMuted)
                    }
                }
            case .failed(let failure):
                inlineError(failure.message, failure: failure)
            case .analysisChanged:
                inlineError("字幕解析刚刚更新了，请按新版本重新生成。", failure: nil)
            case .fingerprintUnavailable:
                inlineError("视频解析版本还没准备好，请刷新后重试。", failure: nil)
            case .idle, .ready:
                Button(action: onGenerate) {
                    Label("生成视频学习导览", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.whatsubAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func inlineError(_ message: String, failure: RemoteFailure?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.whatsubInkSoft)
            HStack(spacing: 12) {
                Button("重试", action: onRetry)
                    .font(.caption.weight(.semibold))
                if failure?.kind == .subscribeUpsell {
                    Button("订阅 Pro", action: onSubscribe)
                        .font(.caption.weight(.semibold))
                } else if failure?.kind == .configureLLM {
                    Button("LLM 设置", action: onConfigureLLM)
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.whatsubAccent)
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
