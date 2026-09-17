import SwiftUI
import Observation

@Observable
public final class ChatViewModel {
    public enum Tab: Hashable { case discussions, tickets }
    public enum Filter: String, CaseIterable, Identifiable {
        case all = "Toutes", unread = "Non lues", groups = "Groupes"
        case pinned = "Épinglées", archived = "Archivées"
        public var id: String { rawValue }
    }

    public private(set) var threads: [ChatThread] = []
    public private(set) var errorMessage: String?
    public var tab: Tab = .discussions
    public var filter: Filter = .all
    public var query = ""
    public var isLoading = false

    private let repository: ChatRepository
    public init(repository: ChatRepository) { self.repository = repository }

    public var visibleThreads: [ChatThread] {
        threads.filter { thread in
            let matchesTab = tab == .tickets ? thread.kind == .ticket : thread.kind != .ticket
            let matchesFilter: Bool
            switch filter {
            case .all:      matchesFilter = !thread.archived
            case .unread:   matchesFilter = thread.unreadCount > 0 && !thread.archived
            case .groups:   matchesFilter = thread.kind == .group
            case .pinned:   matchesFilter = thread.pinned
            case .archived: matchesFilter = thread.archived
            }
            let matchesQuery = query.isEmpty
                || thread.displayName.localizedCaseInsensitiveContains(query)
            return matchesTab && matchesFilter && matchesQuery
        }
        // Pinned first, then most recent, matching how the source app orders.
        .sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return (lhs.lastMessageAt ?? .distantPast) > (rhs.lastMessageAt ?? .distantPast)
        }
    }

    /// Test seam: lets the filter and ordering rules be exercised without a
    /// round trip, since those are where the behaviour actually lives.
    public func injectForTesting(_ threads: [ChatThread]) { self.threads = threads }

    @MainActor
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            threads = try await repository.loadThreads()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct ChatView: View {
    @State private var model: ChatViewModel

    public init(model: ChatViewModel) { _model = State(wrappedValue: model) }

    public var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Text("Chat")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.top, Theme.Spacing.s)

                SegmentedPicker(selection: $model.tab, options: [
                    .init(.discussions, "Discussions"), .init(.tickets, "Tickets")
                ])

                HStack(spacing: Theme.Spacing.m) {
                    SearchField("Rechercher une discussion", text: $model.query)
                    Button {} label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.Palette.brand)
                            .frame(width: 52, height: 52)
                            .cardSurface(radius: Theme.Radius.field)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Nouvelle discussion")
                }

                filterChips

                if model.visibleThreads.isEmpty {
                    emptyState
                } else {
                    List(model.visibleThreads) { thread in
                        ThreadRow(thread: thread)
                            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                            .listRowSeparatorTint(Theme.Palette.hairline)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await model.load() }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.gutter)
        }
        .task { await model.load() }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.m) {
                ForEach(ChatViewModel.Filter.allCases) { filter in
                    let isSelected = model.filter == filter
                    Button { model.filter = filter } label: {
                        Text(filter.rawValue)
                            .font(Theme.Typography.body)
                            .foregroundStyle(isSelected ? .white : Theme.Palette.textPrimary)
                            .padding(.horizontal, Theme.Spacing.xl)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(isSelected ? Theme.Palette.brand
                                                          : Theme.Palette.surface)
                            )
                            .overlay(
                                Capsule().stroke(isSelected ? .clear : Theme.Palette.hairline,
                                                 lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: model.tab == .tickets ? "ticket" : "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(model.tab == .tickets ? "Aucun ticket" : "Aucune discussion")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

struct ThreadRow: View {
    let thread: ChatThread

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            Text(thread.initials)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color(hex: 0x9EEBD3)))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(thread.displayName)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if thread.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                Text(thread.lastMessage ?? "Aucun message")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.s)

            VStack(alignment: .trailing, spacing: Theme.Spacing.s) {
                if let date = thread.lastMessageAt {
                    Text(Self.time.string(from: date))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                if thread.unreadCount > 0 {
                    Text("\(thread.unreadCount)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.Palette.brand))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [thread.displayName, thread.lastMessage ?? "Aucun message"]
        if thread.unreadCount > 0 { parts.append("\(thread.unreadCount) non lus") }
        return parts.joined(separator: ", ")
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()
}
