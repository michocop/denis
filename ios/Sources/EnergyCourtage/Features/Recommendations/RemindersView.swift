import SwiftUI

public struct Reminder: Identifiable, Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case scheduled, sent, done, cancelled
    }

    public let id: UUID
    public var label: String
    public var dueAt: Date
    public var status: Status

    public init(id: UUID, label: String, dueAt: Date, status: Status) {
        self.id = id; self.label = label; self.dueAt = dueAt; self.status = status
    }

    public var isOverdue: Bool { status == .scheduled && dueAt < .now }
}

public protocol RemindersRepository: Sendable {
    func reminders(recommendationID: UUID) async throws -> [Reminder]
    func schedule(recommendationID: UUID, label: String, dueAt: Date) async throws -> Reminder
    func complete(reminderID: UUID) async throws
}

/// `Rappels` from the action sheet. The source app shows the entry but no
/// screen behind it in anything I have seen, so this is built from what the
/// job needs: a quick preset, a real date, and a way to tick one off.
public struct RemindersView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var reminders: [Reminder] = []
    @State private var label = ""
    @State private var dueAt = Date.now.addingTimeInterval(2 * 86_400)
    @State private var errorMessage: String?
    @State private var isWorking = false

    private let recommendationID: UUID
    private let filleulName: String
    private let repository: RemindersRepository

    public init(recommendationID: UUID, filleulName: String,
                repository: RemindersRepository) {
        self.recommendationID = recommendationID
        self.filleulName = filleulName
        self.repository = repository
    }

    private var presets: [(String, TimeInterval)] {
        [("Demain", 86_400), ("Dans 3 jours", 3 * 86_400), ("Dans une semaine", 7 * 86_400)]
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    if !reminders.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                            Text("Rappels programmés")
                                .font(Theme.Typography.body.weight(.semibold))
                                .foregroundStyle(Theme.Palette.textPrimary)
                            ForEach(reminders) { reminder in
                                row(reminder)
                            }
                        }
                        .padding(Theme.Spacing.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    }

                    LabelledField("Intitulé") {
                        TextField("Relancer \(filleulName)", text: $label)
                    }

                    HStack(spacing: Theme.Spacing.s) {
                        ForEach(presets, id: \.0) { preset in
                            Button(preset.0) {
                                dueAt = .now.addingTimeInterval(preset.1)
                            }
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.brand)
                            .padding(.horizontal, Theme.Spacing.l)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Theme.Palette.brandSoft))
                            .buttonStyle(.plain)
                        }
                    }

                    DatePicker("Échéance", selection: $dueAt,
                               in: Date.now...,
                               displayedComponents: [.date, .hourAndMinute])
                        .font(Theme.Typography.body)
                        .tint(Theme.Palette.brand)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                    }

                    PrimaryActionButton(isWorking ? "Enregistrement…" : "Programmer le rappel") {
                        Task { await schedule() }
                    }
                    .disabled(isWorking)
                }
                .padding(Theme.Spacing.gutter)
            }
            .background(Theme.Palette.canvas)
            .navigationTitle(Strings.Actions.reminders)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.Actions.close) { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func row(_ reminder: Reminder) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Button {
                Task {
                    try? await repository.complete(reminderID: reminder.id)
                    await load()
                }
            } label: {
                Image(systemName: reminder.status == .done
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(reminder.status == .done
                                     ? Theme.Palette.success : Theme.Palette.pendingRing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Marquer « \(reminder.label) » comme fait")

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .strikethrough(reminder.status == .done)
                Text(Self.due.string(from: reminder.dueAt))
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(reminder.isOverdue
                                     ? Theme.Palette.staleText : Theme.Palette.textSecondary)
            }
            Spacer()
        }
    }

    private func load() async {
        reminders = (try? await repository.reminders(recommendationID: recommendationID)) ?? []
    }

    private func schedule() async {
        isWorking = true
        defer { isWorking = false }
        let text = label.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Relancer \(filleulName)" : label
        do {
            _ = try await repository.schedule(recommendationID: recommendationID,
                                              label: text, dueAt: dueAt)
            label = ""
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let due: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
