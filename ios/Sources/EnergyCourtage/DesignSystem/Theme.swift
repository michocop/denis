import SwiftUI
#if canImport(UIKit)
import UIKit
import CoreText
#endif

/// Design tokens, taken from trinity-energie.fr so the app and the website
/// read as one brand: a night-navy canvas, one electric blue, glass surfaces
/// with a hairline of light on their edge, Sora for display and Manrope for
/// text. The values are the site's own CSS custom properties (`--bg`,
/// `--navy`, `--blue`, `--blue-hi`, `--ice`, `--glass`, `--glass-edge`).
///
/// The app is dark, like the site. Every colour, radius and type size used
/// anywhere resolves through here, so a brand change is a one-file change.
public enum Theme {

    // MARK: - Colour

    public enum Palette {
        /// `--bg`: the canvas everything sits on.
        public static let night         = Color(hex: 0x03081A)
        /// `--navy`: the glow at the top of the canvas, and the icon tile.
        public static let navy          = Color(hex: 0x0A1F4A)
        /// `--blue`: primary buttons, the selected segment.
        public static let brandFill     = Color(hex: 0x1F5FFF)
        /// `--blue-hi`: tint for links, icons, the current step. Brighter than
        /// the fill, because thin text in #1F5FFF on night does not read.
        public static let brand         = Color(hex: 0x4F95FF)
        public static let brandSoft     = Color(hex: 0x1F5FFF).opacity(0.16)
        /// The end of the headline gradient on the site.
        public static let ice           = Color(hex: 0xC3D7FF)

        /// Completed steps and their connectors.
        public static let success       = Color(hex: 0x34D399)
        /// The reward amount and the status-banner text.
        public static let successText   = Color(hex: 0x5EE6A8)
        public static let successSoft   = Color(hex: 0x34D399).opacity(0.13)

        /// The 🎁 Récompense pill and the demo banner.
        public static let rewardSoft    = Color(hex: 0xF5C451).opacity(0.14)
        public static let rewardText    = Color(hex: 0xF5C451)

        /// `--danger`.
        public static let destructive   = Color(hex: 0xFF8A80)

        /// `--ink`, `--muted`.
        public static let textPrimary   = Color(hex: 0xF5F7FC)
        public static let textSecondary = Color(hex: 0xDCE5F7).opacity(0.58)

        /// What a card is filled with when it is not glass (sheets, menus).
        public static let surface       = Color(hex: 0x0B1430)
        /// The canvas colour, for the few places that need a flat fill.
        public static let canvas        = night
        /// Segmented-control track, fields, read-only blocks: a glass tint.
        public static let track         = Color.white.opacity(0.06)
        public static let grouped       = Color.white.opacity(0.06)
        /// `--hair` / `--glass-edge`.
        public static let hairline      = Color.white.opacity(0.10)

        /// Pending step ring, and the idle connector between steps.
        public static let pendingRing   = Color.white.opacity(0.22)
        public static let connectorIdle = Color.white.opacity(0.12)

        /// Initials in chat and profile.
        public static let avatar        = Color(hex: 0x1F5FFF).opacity(0.28)

        /// A recommendation nobody has touched in a while.
        public static let staleSoft     = Color(hex: 0xFB923C).opacity(0.14)
        public static let staleText     = Color(hex: 0xFDBA74)
    }

    // MARK: - Metrics

    public enum Radius {
        public static let card: CGFloat      = 24
        public static let field: CGFloat     = 16
        public static let segmented: CGFloat = 999
        public static let segmentPill: CGFloat = 999
        /// Buttons are pills, as on the site.
        public static let button: CGFloat    = 999
        public static let modal: CGFloat     = 28
        public static let sheet: CGFloat     = 28
        public static let image: CGFloat     = 14
    }

    public enum Spacing {
        public static let gutter: CGFloat      = 20
        public static let cardPadding: CGFloat = 20
        public static let xs: CGFloat = 4
        public static let s: CGFloat  = 8
        public static let m: CGFloat  = 12
        public static let l: CGFloat  = 16
        public static let xl: CGFloat = 24
    }

    // MARK: - Type
    //
    // Sora for display and Manrope for text: the site's two faces, bundled
    // (SIL Open Font License, see Resources/Fonts). Each style is tied to a
    // system text style, so it grows with the reader's Dynamic Type setting
    // instead of staying fixed. If the fonts fail to register, iOS falls back
    // to the system face rather than to nothing.

    public enum Typography {
        public static let screenTitle = display(32, .semibold, relativeTo: .largeTitle)
        public static let cardTitle   = display(21, .semibold, relativeTo: .title2)
        public static let amount      = display(20, .semibold, relativeTo: .title3)
        public static let body        = text(17, .regular, relativeTo: .body)
        public static let secondary   = text(15, .regular, relativeTo: .subheadline)
        public static let label       = text(15, .medium, relativeTo: .subheadline)
        public static let badge       = text(14, .semibold, relativeTo: .footnote)
        public static let caption     = text(13, .medium, relativeTo: .caption)
        /// The letter-spaced wordmark: "TRINITY ÉNERGIE".
        public static let wordmark    = display(14, .semibold, relativeTo: .footnote)

        public static func display(_ size: CGFloat, _ weight: Font.Weight,
                                   relativeTo style: Font.TextStyle) -> Font {
            Font.custom("Sora", size: size, relativeTo: style).weight(weight)
        }

        public static func text(_ size: CGFloat, _ weight: Font.Weight,
                                relativeTo style: Font.TextStyle) -> Font {
            Font.custom("Manrope", size: size, relativeTo: style).weight(weight)
        }
    }

    public enum Shadow {
        public static let card = (color: Color.black.opacity(0.45), radius: CGFloat(24),
                                  x: CGFloat(0), y: CGFloat(14))
    }

    // MARK: - Fonts

    /// Registers the bundled faces once. Called from the app's root view;
    /// safe to call again.
    public static func registerFonts() {
        #if canImport(UIKit)
        guard !fontsRegistered else { return }
        fontsRegistered = true
        for name in ["Sora", "Manrope"] {
            // copied as a folder (see Package.swift), so they sit under Fonts/
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf",
                                              subdirectory: "Fonts") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        #endif
    }

    nonisolated(unsafe) private static var fontsRegistered = false
}

// MARK: - Helpers

public extension Color {
    /// `Color(hex: 0x1F5FFF)` — keeps the token table readable.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// The canvas: night, with the navy glow the site has at the top of its hero
/// and a faint blue bloom behind it. Used wherever a screen used to paint a
/// flat background.
public struct BrandBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            Theme.Palette.night
            RadialGradient(colors: [Theme.Palette.navy.opacity(0.95), .clear],
                           center: .init(x: 0.5, y: -0.05),
                           startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Theme.Palette.brandFill.opacity(0.16), .clear],
                           center: .init(x: 0.85, y: 0.05),
                           startRadius: 0, endRadius: 300)
        }
        .ignoresSafeArea()
    }
}

public extension View {
    /// The glass card: the site's `--glass` gradient over the canvas, a
    /// hairline of light on the edge (`--glass-edge`), a brighter line along
    /// the top where light would catch it, and a deep soft shadow.
    func cardSurface(radius: CGFloat = Theme.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(
            shape
                .fill(LinearGradient(colors: [Color.white.opacity(0.085),
                                              Color.white.opacity(0.025)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .background(shape.fill(Theme.Palette.night.opacity(0.35)))
                .shadow(color: Theme.Shadow.card.color, radius: Theme.Shadow.card.radius,
                        x: Theme.Shadow.card.x, y: Theme.Shadow.card.y)
        )
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        )
    }

    /// Liquid Glass where the system has it (iOS 26), and the site's glass
    /// recipe -- a translucent material with a light edge -- everywhere else.
    /// For floating controls: buttons, the bell, segmented tracks.
    @ViewBuilder
    func brandGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive()
                                         : Glass.regular.tint(tint), in: shape)
        } else {
            fallbackGlass(in: shape, tint: tint)
        }
        #else
        fallbackGlass(in: shape, tint: tint)
        #endif
    }

    private func fallbackGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        background(shape.fill(.ultraThinMaterial))
            .background(shape.fill(tint ?? Color.white.opacity(0.06)))
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// The Trinity Énergie mark, drawn rather than shipped as a bitmap so it is
/// sharp at every size: an open triangle, and a solid blue one inside it.
/// Geometry from the site's own SVG (`viewBox 0 0 24 22`).
public struct TrinityLogo: View {
    private let size: CGFloat
    private let lineColor: Color

    public init(size: CGFloat = 28, lineColor: Color = Theme.Palette.textPrimary) {
        self.size = size
        self.lineColor = lineColor
    }

    public var body: some View {
        ZStack {
            OuterTriangle()
                .stroke(lineColor, style: StrokeStyle(lineWidth: size * 1.8 / 24,
                                                     lineJoin: .round))
            InnerTriangle()
                .fill(Color(hex: 0x3C8BFF))
        }
        .frame(width: size, height: size * 22 / 24)
        .accessibilityLabel("Trinity Énergie")
    }

    private struct OuterTriangle: Shape {
        func path(in rect: CGRect) -> Path {
            let sx = rect.width / 24, sy = rect.height / 22
            var path = Path()
            path.move(to: CGPoint(x: 12 * sx, y: 1.25 * sy))
            path.addLine(to: CGPoint(x: 22.5 * sx, y: 20.75 * sy))
            path.addLine(to: CGPoint(x: 1.5 * sx, y: 20.75 * sy))
            path.closeSubpath()
            return path
        }
    }

    private struct InnerTriangle: Shape {
        func path(in rect: CGRect) -> Path {
            let sx = rect.width / 24, sy = rect.height / 22
            var path = Path()
            path.move(to: CGPoint(x: 12 * sx, y: 8.75 * sy))
            path.addLine(to: CGPoint(x: 16.5 * sx, y: 17 * sy))
            path.addLine(to: CGPoint(x: 7.5 * sx, y: 17 * sy))
            path.closeSubpath()
            return path
        }
    }
}

/// The mark and the letter-spaced name, as in the site's header.
public struct TrinityWordmark: View {
    private let logoSize: CGFloat
    public init(logoSize: CGFloat = 22) { self.logoSize = logoSize }

    public var body: some View {
        HStack(spacing: 10) {
            TrinityLogo(size: logoSize)
            Text("TRINITY ÉNERGIE")
                .font(Theme.Typography.wordmark)
                .tracking(2.2)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trinity Énergie")
    }
}

/// The site's headline treatment: blue to ice, left to right.
public extension Text {
    func brandGradient() -> some View {
        foregroundStyle(LinearGradient(colors: [Color(hex: 0x4F95FF), Color(hex: 0x7DB0FF),
                                                Theme.Palette.ice],
                                       startPoint: .leading, endPoint: .trailing))
    }
}

#if canImport(UIKit)
extension UIFont {
    /// The same variable face at another weight: Sora and Manrope ship as one
    /// variable font each, so a weight is a trait, not a different file.
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
