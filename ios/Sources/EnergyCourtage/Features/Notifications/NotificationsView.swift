import SwiftUI
import Observation

@Observable
public final class NotificationsViewModel {
    public private(set) var items: [AppNotification] = []
    public private(set) var unread = 0
    public private(set) var errorMessage: String?
    public var isLoading = false

    private let repository: NotificationsRepository
    public init(repository: NotificationsRepository) { self.repository = repository }

    @MainActor
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await repository.notifications()
            unread = try await repository.unreadCount()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Only the count, for the badge. Cheap enough to run on the poller
    /// without pulling the whole list down every thirty seconds.
    @MainActor
    public func refreshBadge() async {
        unread = (try? await repository.unreadCount()) ?? unread
    }

    /// Reading the list is what marks it read — there is nothing useful about
    /// making someone tap each row to clear a badge.
    @MainActor
    public func markRead() async {
        guard unread > 0 else { return }
        do {
            try await repository.markAllRead()
            unread = 0
            items = items.map { item in
                var copy = item
                if copy.readAt == nil { copy.readAt = .now }
                return copy
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct NotificationsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: NotificationsViewModel

    public init(model: NotificationsViewModel) { _model = State(wrappedValue: model) }

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()

                if model.items.isEmpty {
                    empty
                } else {
                    List(model.items) { item in
                        row(item)
                            .listRowBackground(Theme.Palette.canvas)
                            .listRowSeparatorTint(Theme.Palette.hairline)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await model.load() }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .task {
            await model.load()
            await model.markRead()
        }
    }

    private func row(_ item: AppNotification) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.l) {
            Image(systemName: item.icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.Palette.brand)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.Palette.brand.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(Theme.Typography.body.weight(item.isUnread ? .semibold : .regular))
                    .foregroundStyle(Theme.Palette.textPrimary)
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(Self.relative.localizedString(for: item.createdAt, relativeTo: .now))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var empty: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "bell")
                .font(.system(size: 34))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("Aucune notification")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .short
        return f
    }()
}
