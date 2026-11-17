import SwiftUI
import Observation

@Observable
public final class AppointmentsViewModel {
    public private(set) var appointments: [Recommendation] = []
    public private(set) var hasLoaded = false
    public private(set) var errorMessage: String?

    private let repository: RecommendationsRepository
    public init(repository: RecommendationsRepository) { self.repository = repository }

    public var schedule: AppointmentSchedule { AppointmentSchedule(appointments) }

    /// Only after an answer: "Aucun rendez-vous fixé." said while loading, or
    /// after a failure, tells the company something that may not be true.
    public var isEmpty: Bool { hasLoaded && appointments.isEmpty }

    @MainActor
    public func load() async {
        do {
            appointments = try await repository.appointments()
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Throws, so the sheet that asked stays open with the reason.
    @MainActor
    public func setAppointment(_ date: Date?, on recommendationID: UUID) async throws {
        _ = try await repository.setAppointment(recommendationID: recommendationID, at: date)
        await load()
    }
}

/// Every meeting in one place, in order, rather than scattered across the leads.
public struct AppointmentsView: View {
    @State private var model: AppointmentsViewModel
    @State private var editing: Recommendation?

    public init(model: AppointmentsViewModel) { _model = State(wrappedValue: model) }

    public var body: some View {
        ZStack {
            BrandBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Rendez-vous")
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.top, Theme.Spacing.s)

                    content

                    if let message = model.errorMessage {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .refreshable { await model.load() }
        }
        .task { await model.load() }
        .sheet(item: $editing) { reco in
            AppointmentSheet(recommendation: reco) { date in
                try await model.setAppointment(date, on: reco.id)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isEmpty {
            VStack(spacing: Theme.Spacing.m) {
                Image(systemName: "calendar")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("Aucun rendez-vous fixé.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 56)
        } else if !model.hasLoaded {
            if model.errorMessage == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 56)
            }
        } else {
            let schedule = model.schedule
            section("À venir", schedule.upcoming, past: false)
            section("Passés", schedule.past, past: true)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ appointments: [Recommendation],
                         past: Bool) -> some View {
        if !appointments.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text(title)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                ForEach(appointments) { reco in
                    row(reco, past: past)
                }
            }
        }
    }

    private func row(_ reco: Recommendation, past: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Button { editing = reco } label: {
                HStack(spacing: Theme.Spacing.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dateLine(reco))
                            .font(Theme.Typography.cardTitle)
                            .foregroundStyle(past ? Theme.Palette.textSecondary
                                                  : Theme.Palette.textPrimary)
                            .multilineTextAlignment(.leading)
                        Text(reco.filleulName)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text("Recommandé par \(reco.parrainName)")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Beside the row's button, not in it: a link inside a button's
            // label is never reached.
            if let phone = reco.filleulPhone, !phone.isEmpty,
               let dial = URL(string: "tel:" + phone.filter({ !$0.isWhitespace })) {
                Link(destination: dial) {
                    Label(phone, systemImage: "phone")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.brand)
                }
                .accessibilityLabel("Appeler \(reco.filleulName)")
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// The row opens on it, so it takes the capital the mid-sentence form doesn't.
    private func dateLine(_ reco: Recommendation) -> String {
        guard let date = reco.appointmentAt else { return "" }
        let text = RecommendationCard.appointmentDate(date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
