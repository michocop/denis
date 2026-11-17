import SwiftUI

/// The date and time of a meeting, the same in the form and in the sheet.
struct AppointmentPicker: View {
    @Binding var selection: Date
    let earliest: Date

    var body: some View {
        DatePicker("Date et heure", selection: $selection,
                   in: earliest...,
                   displayedComponents: [.date, .hourAndMinute])
            .font(Theme.Typography.body)
            .tint(Theme.Palette.brand)
            .environment(\.locale, Locale(identifier: "fr_FR"))
    }
}

/// Fixes, moves or removes a lead's meeting. Saved when a button is tapped; if
/// that fails the sheet stays open and says so, rather than closing as if the
/// meeting had moved.
public struct AppointmentSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let recommendation: Recommendation
    /// Never after a meeting already past: the picker would show now while
    /// the sheet still held the old date, and "Enregistrer" would save that.
    private let earliest: Date
    private let save: (Date?) async throws -> Void

    public init(recommendation: Recommendation,
                save: @escaping (Date?) async throws -> Void) {
        self.recommendation = recommendation
        self.save = save
        earliest = min(recommendation.appointmentAt ?? .now, .now)
        _date = State(initialValue: recommendation.appointmentAt ?? AppointmentSchedule.defaultDate())
    }

    private var canSave: Bool { !isSaving && date != recommendation.appointmentAt }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text(recommendation.filleulName)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)

                    AppointmentPicker(selection: $date, earliest: earliest)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PrimaryActionButton(isSaving ? "Enregistrement…" : Strings.Actions.save) {
                        Task { await commit(date) }
                    }
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)

                    if recommendation.appointmentAt != nil {
                        Button(role: .destructive) {
                            Task { await commit(nil) }
                        } label: {
                            Text("Retirer le rendez-vous")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.destructive)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .disabled(isSaving)
                    }
                }
                .padding(Theme.Spacing.gutter)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(BrandBackground())
            .navigationTitle("Rendez-vous")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.Actions.cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .errorFeedback(errorMessage)
    }

    private func commit(_ date: Date?) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await save(date)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
