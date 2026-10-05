import SwiftUI

/// How things move, kept in one place for the same reason the colours are:
/// two screens that animate on different springs feel like two apps.
///
/// Every effect here steps aside when the reader has asked iOS to reduce
/// motion: what slides or zooms elsewhere only fades.
public enum Motion {
    /// Content arriving on screen.
    public static let appear = Animation.spring(response: 0.55, dampingFraction: 0.85)

    /// The gap between two items of a cascade.
    public static let staggerStep: Double = 0.045
    /// Past this many items the rest arrive together: a long list that
    /// trickled in one card at a time would take seconds to settle.
    public static let staggerLimit = 8

    public static func staggerDelay(index: Int) -> Double {
        Double(min(max(index, 0), staggerLimit)) * staggerStep
    }
}

// MARK: - Revealed

private struct ContentRevealedKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    /// False while the opening still covers the screen. Whatever announces
    /// itself on arrival -- a cascade, the Face ID prompt -- waits for it,
    /// rather than playing out underneath where nobody sees it.
    var contentRevealed: Bool {
        get { self[ContentRevealedKey.self] }
        set { self[ContentRevealedKey.self] = newValue }
    }
}

// MARK: - Cascade

private struct StaggeredAppear: ViewModifier {
    let index: Int
    let isActive: Bool

    @Environment(\.contentRevealed) private var revealed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear(perform: reveal)
            .onChange(of: isActive && revealed) { _, ready in
                if ready { reveal() }
            }
    }

    private func reveal() {
        guard isActive, revealed, !shown else { return }
        withAnimation(Motion.appear.delay(Motion.staggerDelay(index: index))) { shown = true }
    }
}

public extension View {
    /// Rises into place as part of a cascade, `index` steps after the first
    /// item, once `active` holds (the data it shows has arrived, say) and
    /// the opening has gone.
    func staggeredAppear(index: Int, when active: Bool = true) -> some View {
        modifier(StaggeredAppear(index: index, isActive: active))
    }
}

// MARK: - Shimmer

private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        LinearGradient(colors: [.clear, Color.white.opacity(0.14), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 0.6)
                            .offset(x: -width * 0.6 + phase * width * 1.6)
                    }
                    .mask(content)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

public extension View {
    /// A band of light sweeping across a placeholder, the way loading reads
    /// in the apps people trust with money. Only the shapes it covers catch it.
    func shimmering() -> some View {
        modifier(Shimmer())
    }
}
