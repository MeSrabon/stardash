import SwiftUI

/// The two looks the app ships with. Glass is the original; Mono is black, white and sharp-edged.
enum AppTheme: String, CaseIterable, Identifiable {
    case glass, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: return "Glass"
        case .mono: return "Mono"
        }
    }

    var detail: String {
        switch self {
        case .glass: return "Frosted panels, colour and soft corners"
        case .mono: return "Black and white, sharp edges, mission-control type"
        }
    }
}

/// Design tokens. Views read these while drawing, so changing the setting restyles everything.
enum Theme {
    /// Mono is the app's one look. Glass is no longer offered; its branches remain only until they're cleared out.
    static var current: AppTheme { .mono }
    static var isMono: Bool { current == .mono }

    /// Corner radius for the current theme.
    static func r(_ base: CGFloat) -> CGFloat { isMono ? min(base, 2) : base }

    /// Space above a page's title.
    static var paneTop: CGFloat { isMono ? 24 : 40 }

    /// Headline type: big titles and hero numbers.
    static func display(_ size: CGFloat) -> Font {
        isMono ? .custom("DIN Alternate", fixedSize: size * 0.9) : .system(size: size, weight: .thin)
    }

    /// Secondary numerals.
    static func number(_ size: CGFloat) -> Font {
        isMono ? .custom("DIN Alternate", fixedSize: size * 0.92) : .system(size: size, weight: .light)
    }

    /// Titles are set in capitals in Mono.
    static func title(_ text: String) -> String { isMono ? text.uppercased() : text }
    static var titleKerning: CGFloat { isMono ? 1.5 : -0.4 }

    /// Tint for switches and filled buttons, which need a colour that white text reads on.
    static var control: Color { Color(red: 0.16, green: 0.50, blue: 1.0) }
    /// Text colour on top of an accent-filled shape.
    static var onAccent: Color { isMono ? .black : .white }

    static var panelFill: Color { .white.opacity(isMono ? 0.035 : 0.05) }
    static var panelStroke: LinearGradient {
        isMono
            ? LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.16)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A capsule in Glass, a squared-off bar in Mono.
struct Pillow: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = Theme.isMono ? min(2, r.height / 2) : r.height / 2
        return Path(roundedRect: r, cornerRadius: max(0, min(radius, r.width / 2)), style: .continuous)
    }

    func inset(by amount: CGFloat) -> Pillow { Pillow(inset: inset + amount) }
}
