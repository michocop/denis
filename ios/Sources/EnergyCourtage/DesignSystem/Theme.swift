import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Design tokens sampled from the source app's screenshots.
///
/// Every colour, radius and type size used by the clone resolves through here,
/// so matching the original more precisely later is a one-file change rather
/// than a hunt through views.
public enum Theme {

    // MARK: - Colour
    //
    // The source app is light-only. Every token here carries a dark
    // counterpart so the app follows the system instead of glaring at someone
    // checking a recommendation at night — the screenshots' exact values are
    // the light side, unchanged.

    public enum Palette {
        /// Tint: primary buttons, links, the active tab, the current-step ring.
        public static let brand         = adaptive(light: 0x2196D3, dark: 0x4FB3E8)
        public static let brandSoft     = adaptive(light: 0xE3F2FB, dark: 0x10303F)

        /// Completed steps and their connectors.
        public static let success       = adaptive(light: 0x22C55E, dark: 0x34D06F)
        /// The green reward amount and the status-banner text.
        public static let successText   = adaptive(light: 0x16A34A, dark: 0x4ADE80)
        public static let successSoft   = adaptive(light: 0xDCFCE7, dark: 0x0E2C1B)

        /// The 🎁 Récompense pill.
        public static let rewardSoft    = adaptive(light: 0xFEF3C7, dark: 0x3A2E0B)
        public static let rewardText    = adaptive(light: 0xB45309, dark: 0xF5C451)

        public static let destructive   = adaptive(light: 0xFF3B30, dark: 0xFF6961)

        public static let textPrimary   = adaptive(light: 0x111827, dark: 0xF2F2F7)
        public static let textSecondary = adaptive(light: 0x9CA3AF, dark: 0x8E8E93)

        public static let surface       = adaptive(light: 0xFFFFFF, dark: 0x1C1C1E)
        public static let canvas        = adaptive(light: 0xFFFFFF, dark: 0x000000)
        /// Segmented-control track and the read-only message block.
        public static let track         = adaptive(light: 0xF1F2F4, dark: 0x2C2C2E)
        /// Grouped action lists inside the bottom sheet.
        public static let grouped       = adaptive(light: 0xF2F2F7, dark: 0x2C2C2E)
        public static let hairline      = adaptive(light: 0xE5E7EB, dark: 0x38383A)

        /// Pending step ring, and the idle connector between steps.
        public static let pendingRing   = adaptive(light: 0xD1D5DB, dark: 0x48484A)
        public static let connectorIdle = adaptive(light: 0xE5E7EB, dark: 0x3A3A3C)

        /// Avatar background in chat and profile.
        public static let avatar        = adaptive(light: 0x9EEBD3, dark: 0x1F4D40)

        /// A recommendation nobody has touched in a while.
        public static let staleSoft     = adaptive(light: 0xFFF1E6, dark: 0x3A2415)
        public static let staleText     = adaptive(light: 0xC2410C, dark: 0xFDBA74)

        /// Resolved per trait collection so the whole palette follows the
        /// system appearance. Guarded because UIKit is not present on every
        /// platform the package can be compiled for.
        private static func adaptive(light: UInt32, dark: UInt32) -> Color {
            #if canImport(UIKit)
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(Color(hex: dark))
                    : UIColor(Color(hex: light))
            })
            #else
            return Color(hex: light)
            #endif
        }
    }

    // MARK: - Metrics

    public enum Radius {
        public static let card: CGFloat      = 18
        public static let field: CGFloat     = 14
        public static let segmented: CGFloat = 14
        public static let segmentPill: CGFloat = 12
        public static let button: CGFloat    = 12
        public static let modal: CGFloat     = 24
        public static let sheet: CGFloat     = 24
        public static let image: CGFloat     = 12
    }

    public enum Spacing {
        public static let gutter: CGFloat      = 16
        public static let cardPadding: CGFloat = 20
        public static let xs: CGFloat = 4
        public static let s: CGFloat  = 8
        public static let m: CGFloat  = 12
        public static let l: CGFloat  = 16
        public static let xl: CGFloat = 24
    }

    // MARK: - Type
    //
    // The original appears to use a geometric sans (Poppins / Figtree family).
    // Until the real face is licensed, everything routes through these helpers
    // so swapping in a custom font touches one file.

    public enum Typography {
        public static let screenTitle = Font.system(size: 30, weight: .semibold)
        public static let cardTitle   = Font.system(size: 22, weight: .semibold)
        public static let amount      = Font.system(size: 20, weight: .semibold)
        public static let body        = Font.system(size: 17, weight: .regular)
        public static let secondary   = Font.system(size: 16, weight: .regular)
        public static let label       = Font.system(size: 15, weight: .regular)
        public static let badge       = Font.system(size: 14, weight: .medium)
        public static let caption     = Font.system(size: 13, weight: .medium)
    }

    public enum Shadow {
        public static let card = (color: Color.black.opacity(0.06), radius: CGFloat(10),
                                  x: CGFloat(0), y: CGFloat(2))
    }
}

// MARK: - Helpers

public extension Color {
    /// `Color(hex: 0x2196D3)` — keeps the token table readable.
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

public extension View {
    /// The card treatment shared by recommendations, members and the
    /// refresh banner.
    func cardSurface(radius: CGFloat = Theme.Radius.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.Palette.surface)
                .shadow(color: Theme.Shadow.card.color,
                        radius: Theme.Shadow.card.radius,
                        x: Theme.Shadow.card.x,
                        y: Theme.Shadow.card.y)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Theme.Palette.hairline, lineWidth: 1)
        )
    }
}
