import SwiftUI

// Brand palette — single source of truth, mirrored from the desktop client
// (client/src/components/WelcomeIntro.tsx) and the website brand tokens
// (whatsub-website/src/app/globals.css). 三件套必须保持一致：黑 / 蓝 / 黄。
extension Color {
    /// Page canvas — pure black (#000000).
    static let whatsubBg = Color.black

    /// Alternating section background (#0a0a0c).
    static let whatsubBgSoft = Color(red: 0x0A / 255.0, green: 0x0A / 255.0, blue: 0x0C / 255.0)

    /// Card / elevated surface (#141418).
    static let whatsubBgElev = Color(red: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x18 / 255.0)

    /// Primary text (#ffffff).
    static let whatsubInk = Color.white

    /// Body text — 72% white (matches --ink-soft on website).
    static let whatsubInkSoft = Color.white.opacity(0.72)

    /// Secondary text / muted — 48% white (matches --ink-muted).
    static let whatsubInkMuted = Color.white.opacity(0.48)

    /// Timestamps / mono labels — 30% white (matches --ink-faint).
    static let whatsubInkFaint = Color.white.opacity(0.30)

    /// Brand accent — blue (#3B9BFF). Used for "Sub" wordmark, CTA buttons,
    /// single accent word per section title.
    static let whatsubAccent = Color(red: 0x3B / 255.0, green: 0x9B / 255.0, blue: 0xFF / 255.0)

    /// Highlight color for AI-flagged phrases — amber (#FCD34D). English
    /// underline + spot-color in bilingual subtitles.
    static let whatsubHighlight = Color(red: 0xFC / 255.0, green: 0xD3 / 255.0, blue: 0x4D / 255.0)
}

// Lift Color statics into ShapeStyle so leading-dot shorthand works in
// .foregroundStyle(.whatsubAccent) / .fill(.whatsubBg) / etc. (SwiftUI
// requires the static member to live on ShapeStyle for that sugar — defining
// it only on Color compiles for `Color.whatsubAccent` but not the `.whatsubAccent`
// form. This mirrors how SwiftUI ships .red / .blue / etc.)
extension ShapeStyle where Self == Color {
    static var whatsubBg: Color { Color.whatsubBg }
    static var whatsubBgSoft: Color { Color.whatsubBgSoft }
    static var whatsubBgElev: Color { Color.whatsubBgElev }
    static var whatsubInk: Color { Color.whatsubInk }
    static var whatsubInkSoft: Color { Color.whatsubInkSoft }
    static var whatsubInkMuted: Color { Color.whatsubInkMuted }
    static var whatsubInkFaint: Color { Color.whatsubInkFaint }
    static var whatsubAccent: Color { Color.whatsubAccent }
    static var whatsubHighlight: Color { Color.whatsubHighlight }
}
