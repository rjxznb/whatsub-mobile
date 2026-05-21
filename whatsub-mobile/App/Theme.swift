import SwiftUI

extension Color {
    /// Brand accent — matches desktop client / website (#3B9BFF).
    static let whatsubAccent = Color(red: 0x3B / 255.0, green: 0x9B / 255.0, blue: 0xFF / 255.0)

    /// Highlight color for AI-flagged phrases (#FCD34D).
    static let whatsubHighlight = Color(red: 0xFC / 255.0, green: 0xD3 / 255.0, blue: 0x4D / 255.0)
}

// Lift Color statics into ShapeStyle so leading-dot shorthand works in
// .foregroundStyle(.whatsubAccent) / .fill(.whatsubAccent) / etc. (SwiftUI
// requires the static member to live on ShapeStyle for that sugar — defining
// it only on Color compiles for `Color.whatsubAccent` but not the `.whatsubAccent`
// form. This mirrors how SwiftUI ships .red / .blue / etc.)
extension ShapeStyle where Self == Color {
    static var whatsubAccent: Color { Color.whatsubAccent }
    static var whatsubHighlight: Color { Color.whatsubHighlight }
}
