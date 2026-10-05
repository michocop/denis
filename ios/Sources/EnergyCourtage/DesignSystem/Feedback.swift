import SwiftUI

/// The app's vibrations, named for what happened rather than for how they
/// feel, so every screen says the same thing the same way and the feel can be
/// tuned here once.
///
/// Rare on purpose. A phone that buzzes on every tap reads as a toy; one that
/// answers only the moments that matter reads as an instrument. So: nothing on
/// secondary buttons, scrolling or typing, and never two at the same instant
/// (pressing "Valider l'étape" and the stage going through are two moments,
/// a network round-trip apart). The system setting for vibrations is honoured
/// by iOS itself.
public enum Feedback {
    /// A choice among equals: a tab, a segment, a card opened or closed.
    case selection
    /// The press of a primary button, felt before the network answers.
    case tap
    /// Something that actually went through: a stage, a signature, an unlock.
    case success
    /// A heavy action carried out: a deal closed as lost, a credit note.
    case warning
    /// Something that did not go through.
    case error
    /// The wave leaving the logo when the app opens.
    case pulse

    var sensory: SensoryFeedback {
        switch self {
        case .selection: return .selection
        case .tap:       return .impact(weight: .light)
        case .success:   return .success
        case .warning:   return .warning
        case .error:     return .error
        case .pulse:     return .impact(flexibility: .soft, intensity: 0.8)
        }
    }
}

public extension View {
    /// Plays `kind` whenever `trigger` changes.
    func feedback<T: Equatable>(_ kind: Feedback, trigger: T) -> some View {
        sensoryFeedback(kind.sensory, trigger: trigger)
    }

    /// Plays `kind` when `trigger` changes and `condition` approves the change
    /// -- an error message appearing, say, but not the same one going away.
    func feedback<T: Equatable>(_ kind: Feedback, trigger: T,
                                condition: @escaping (T, T) -> Bool) -> some View {
        sensoryFeedback(kind.sensory, trigger: trigger, condition: condition)
    }

    /// Plays `.error` each time an error message appears.
    func errorFeedback(_ message: String?) -> some View {
        feedback(.error, trigger: message) { _, new in new != nil }
    }
}
