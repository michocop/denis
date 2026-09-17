import SwiftUI

/// Design tokens sampled from the source app's screenshots.
///
/// Every colour, radius and type size used by the clone resolves through here,
/// so matching the original more precisely later is a one-file change rather
/// than a hunt through views.
public enum Theme {

    // MARK: - Colour

    public enum Palette {
        /// Tint: primary buttons, links, the active tab, the current-step ring.
        public static let brand         = Color(hex: 0x2196D3)
        public static let brandSoft     = Color(hex: 0xE3F2FB)

        /// Completed steps and their connectors.
        public static let success       = Color(hex: 0x22C55E)
        /// The green reward amount and the status-banner text.
        public static let successText   = Color(hex: 0x16A34A)
        public static let successSoft   = Color(hex: 0xDCFCE7)

        /// The 🎁 Récompense pill.
        public static let rewardSoft    = Color(hex: 0xFEF3C7)
        public static let rewardText    = Color(hex: 0xB45309)

        public static let destructive   = Color(hex: 0xFF3B30)

        public static let textPrimary   = Color(hex: 0x111827)
        public static let textSecondary = Color(hex: 0x9CA3AF)

        public static let surface       = Color.white
        public static let canvas        = Color(hex: 0xFFFFFF)
        /// Segmented-control track and the read-only message block.
        public static let track         = Color(hex: 0xF1F2F4)
        /// Grouped action lists inside the bottom sheet.
        public static let grouped       = Color(hex: 0xF2F2F7)
        public static let hairline      = Color(hex: 0xE5E7EB)

        /// Pending step ring, and the idle connector between steps.
        public static let pendingRing   = Color(hex: 0xD1D5DB)
        public static let connectorIdle = Color(hex: 0xE5E7EB)
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
    /// The card treatment shared by recommendations, catalogue products and
    /// the refresh banner.
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
