import SwiftUI

/// When the opening may hand over: once it has played, and once the app knows
/// which screen comes next. Kept apart from the view so the rule can be tested
/// without waiting on an animation.
struct LaunchGate: Equatable {
    private(set) var hasPlayed = false
    private(set) var sessionKnown = false

    mutating func animationFinished() { hasPlayed = true }
    mutating func sessionResolved() { sessionKnown = true }

    var canLeave: Bool { hasPlayed && sessionKnown }
    /// Played, and still waiting on the network: the logo breathes.
    var isWaiting: Bool { hasPlayed && !sessionKnown }
}

/// The opening, "Impulsion": the launch screen iOS draws, brought to life.
///
/// Its first frame is the launch screen -- the same night, the same mark at
/// the same size in the same place -- so there is no jump between the two.
/// Then the inner triangle charges, two waves leave it with a soft knock,
/// and the name is drawn in from the left. About a second in all, played
/// while the session is restored rather than after it; if that takes longer,
/// the mark breathes where a spinner used to turn.
struct LaunchIntroView: View {
    /// Whether the app knows what to show next.
    let isSessionKnown: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gate = LaunchGate()
    @State private var charge: Double = 0
    /// Starts as the launch screen draws the mark, and becomes the brand's
    /// blue inside the pulse, where the change cannot be seen.
    @State private var innerColor = LaunchIntroView.launchScreenBlue
    @State private var pulses = 0
    @State private var nameReveal: CGFloat = 0
    @State private var hasLeft = false

    /// `LaunchLogo` is a 96 pt square with the mark inset in it; this is the
    /// mark's own width at that size, measured off logo@3x.png.
    static let logoSize: CGFloat = 86.4
    private static let logoHeight = logoSize * 22 / 24

    /// iOS draws the launch image's colours as Display P3, so its #3C8BFF
    /// shows as a deeper blue than the same value in sRGB (measured off a
    /// screenshot: 0,141,255 against 60,139,255). The first frame matches the
    /// launch screen, not the brand, or the mark would visibly change colour
    /// the instant the app takes over.
    static let launchScreenBlue = Color(.displayP3, red: 0x3C / 255, green: 0x8B / 255, blue: 1)

    var body: some View {
        ZStack {
            // the colour of the LaunchBackground asset
            Theme.Palette.night.ignoresSafeArea()

            TrinityLogo(size: Self.logoSize, innerColor: innerColor, charge: charge)
                // Behind the mark, and outside its layout: as the waves grow
                // they must not move the mark or push the name down.
                .background {
                    ZStack {
                        wave(delay: 0, peak: 0.9, lineWidth: 1.6)
                        wave(delay: 0.13, peak: 0.6, lineWidth: 1.1)
                    }
                }
                .overlay(alignment: .bottom) { name }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trinity Énergie")
        .feedback(.pulse, trigger: pulses)
        .task { await play() }
        .onChange(of: isSessionKnown, initial: true) { _, known in
            guard known else { return }
            gate.sessionResolved()
            leaveIfReady()
        }
        .onChange(of: gate.isWaiting) { _, waiting in
            guard waiting, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                charge = 0.5
            }
        }
    }

    /// "TRINITY ÉNERGIE", drawn in under the mark. An overlay, so the mark
    /// stays exactly where the launch screen put it.
    private var name: some View {
        Text("TRINITY ÉNERGIE")
            .font(Theme.Typography.wordmark)
            .tracking(3.2)
            .foregroundStyle(Theme.Palette.textPrimary)
            .fixedSize()
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: reduceMotion ? 1 : nameReveal, y: 1, anchor: .leading)
            }
            .opacity(nameReveal)
            .alignmentGuide(.bottom) { $0[.top] - 34 }
    }

    /// A ring of light leaving the inner triangle, `delay` after the pulse.
    private func wave(delay: Double, peak: Double, lineWidth: CGFloat) -> some View {
        Circle()
            .strokeBorder(Theme.Palette.brand, lineWidth: lineWidth)
            .keyframeAnimator(initialValue: WaveFrame(), trigger: pulses) { ring, frame in
                ring.frame(width: frame.diameter, height: frame.diameter)
                    .opacity(frame.opacity)
            } keyframes: { _ in
                // Lit only once it has cleared the mark: a ring drawn across
                // the triangle reads as clutter, not as a wave leaving it.
                KeyframeTrack(\.diameter) {
                    LinearKeyframe(40, duration: max(delay, 0.001))
                    SpringKeyframe(340, duration: 0.9, spring: .smooth(duration: 0.9))
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: max(delay, 0.001))
                    LinearKeyframe(0, duration: 0.08)
                    LinearKeyframe(peak, duration: 0.12)
                    LinearKeyframe(0, duration: 0.7)
                }
            }
            // centred on the inner triangle rather than on the whole mark
            .offset(y: (TrinityLogo.innerCentroid.y - 0.5) * Self.logoHeight)
            .allowsHitTesting(false)
    }

    @MainActor
    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) {
                nameReveal = 1
                innerColor = TrinityLogo.innerBlue
            }
            try? await Task.sleep(for: .milliseconds(350))
        } else {
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(.easeIn(duration: 0.12)) {
                charge = 1
                innerColor = TrinityLogo.innerBlue
            }
            try? await Task.sleep(for: .milliseconds(120))
            pulses += 1
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { charge = 0 }
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(.easeOut(duration: 0.4)) { nameReveal = 1 }
            try? await Task.sleep(for: .milliseconds(450))
        }
        gate.animationFinished()
        leaveIfReady()
    }

    private func leaveIfReady() {
        guard gate.canLeave, !hasLeft else { return }
        hasLeft = true
        onFinished()
    }
}

private struct WaveFrame {
    var diameter: CGFloat = 40
    var opacity: Double = 0
}

#Preview("Ouverture") {
    LaunchIntroView(isSessionKnown: false) {}
}
