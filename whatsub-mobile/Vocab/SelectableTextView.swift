import SwiftUI
import UIKit

/// A non-editable, selectable `UITextView` wrapped for SwiftUI. It reports the
/// currently-selected substring live (via the selection-changed delegate) so a
/// sibling 「加入词汇本」 button can read the last non-empty selection even after the
/// selection clears when focus leaves the text view. Lives inside CollectSheet,
/// so it never competes with the subtitle list's tap-to-seek.
struct SelectableTextView: UIViewRepresentable {
    let text: String
    /// Called with the trimmed selection whenever a non-empty range is selected.
    var onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.font = .systemFont(ofSize: 20, weight: .medium)
        tv.textColor = .white
        tv.tintColor = UIColor(red: 0xFC / 255.0, green: 0xD3 / 255.0, blue: 0x4D / 255.0, alpha: 1) // brand yellow selection
        tv.delegate = context.coordinator
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
        context.coordinator.onSelect = onSelect
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSelect: (String) -> Void
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Only report non-empty selections — so the value survives the button
            // tap (which clears the selection). The sheet shows what will be saved.
            guard let range = textView.selectedTextRange, !range.isEmpty,
                  let selected = textView.text(in: range)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !selected.isEmpty else { return }
            onSelect(selected)
        }
    }
}
