import SwiftUI

extension FeatureEntryPresentation {
    var badgeText: String? {
        switch self {
        case .freeTrial: return "免费体验 1 次"
        case .continueTrial: return "继续免费体验"
        case .normal, .subscriptionRequired, .temporarilyUnavailable: return nil
        }
    }

    var requiresSubscription: Bool {
        self == .subscriptionRequired
    }
}

/// Shared, deliberately lightweight entry marker. Pro, consumed and unknown
/// states render no badge; their behavior is expressed when the user taps.
struct FeatureTrialBadge: View {
    let presentation: FeatureEntryPresentation

    @ViewBuilder
    var body: some View {
        if let text = presentation.badgeText {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.whatsubAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.whatsubAccent.opacity(0.12), in: Capsule())
                .accessibilityLabel(text)
        }
    }
}
