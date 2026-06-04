import SwiftUI

/// Bilingual review surface for the 拍照识别 flow. Renders:
///
///   ┌─────────────────────────────────────────────┐
///   │ 原文 (English)                              │
///   │ The quick brown [fox jumped over] the      │   ← golden bg on
///   │ lazy [dog]. ...                             │     each phrase
///   ├─────────────────────────────────────────────┤
///   │ 翻译 (Chinese)                              │
///   │ 这只敏捷的棕色狐狸……                          │
///   ├─────────────────────────────────────────────┤
///   │ 重点短语 (3 / 5 已选)                         │
///   │ ☑ fox jumped over · 跳过                    │
///   │ ☐ piece of cake · 小菜一碟                   │
///   │ ...                                          │
///   └─────────────────────────────────────────────┘
///
/// Why a phrase-list section at the bottom instead of in-text taps on
/// the highlights themselves? SwiftUI `Text` concatenation can't
/// hit-test individual runs (we hit the same SwiftUI-can't-do-tap-per-
/// run wall the Library subtitle reader hit). A list with checkboxes
/// is both functional + reads as "things to pick" which is the
/// user's actual mental model anyway.
///
/// 2026-06-04 (拍照识别短语).
struct BilingualHighlightView: View {
    let english: String
    let translation: String
    let phrases: [PhotoPhrase]
    let selected: Set<UUID>
    let onTogglePhrase: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ---- 原文 with highlighted phrases ----
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("原文", systemImage: "doc.plaintext")
                Text(highlightedEnglish())
                    .font(.system(size: 17))
                    .foregroundStyle(.whatsubInk)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))

            // ---- 翻译 ----
            if !translation.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("翻译", systemImage: "character.bubble")
                    Text(translation)
                        .font(.system(size: 16))
                        .foregroundStyle(.whatsubInkMuted)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
            }

            // ---- 重点短语 list ----
            if !phrases.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(
                        "重点短语 (\(selected.count) / \(phrases.count) 已选)",
                        systemImage: "star.fill"
                    )
                    VStack(spacing: 6) {
                        ForEach(phrases) { p in
                            phraseRow(p)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func phraseRow(_ p: PhotoPhrase) -> some View {
        Button {
            onTogglePhrase(p.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected.contains(p.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected.contains(p.id)
                                     ? Color.whatsubAccent
                                     : Color.whatsubInkFaint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(p.phrase)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.whatsubInk)
                        if let m = p.meaningZh {
                            Text("· \(m)")
                                .font(.caption)
                                .foregroundStyle(.whatsubInkMuted)
                                .lineLimit(1)
                        }
                    }
                    if let note = p.usageNote, !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.whatsubInkFaint)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                selected.contains(p.id)
                    ? Color.whatsubAccent.opacity(0.10)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.whatsubAccent)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.whatsubInkMuted)
        }
    }

    /// Build an AttributedString with golden-background runs for each
    /// phrase found in the English text (case-insensitive, first-match
    /// only). Multiple phrases compose; overlapping phrases prefer the
    /// earlier-listed one (LLM returns them in source order so this is
    /// fine).
    private func highlightedEnglish() -> AttributedString {
        var attr = AttributedString(english)
        // Color the selected phrases differently so the user gets
        // visual confirmation of their picks WITHOUT having to leave
        // this view to check the list below.
        for p in phrases {
            let isSelected = selected.contains(p.id)
            let needle = p.phrase
            guard !needle.isEmpty else { continue }
            // .range(of:) on AttributedString respects case-insensitive
            // search via String comparison fallback.
            if let range = attr.range(of: needle, options: [.caseInsensitive]) {
                if isSelected {
                    attr[range].backgroundColor = .green.opacity(0.30)
                    attr[range].foregroundColor = .white
                } else {
                    attr[range].backgroundColor = .yellow.opacity(0.20)
                }
                attr[range].font = .system(size: 17, weight: .semibold)
            }
        }
        return attr
    }
}
