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

    /// Who "me" is, needed to tell my bubbles from theirs. Resolved once on
    /// load; until it arrives the detail screen is not reachable, because a
    /// conversation where every bubble is on the same side is worse than a
    /// spinner.
    public private(set) var currentUserID: UUID?
    public private(set) var isAdmin = false
    public private(set) var contacts: [MemberOverview] = []

    private let repository: ChatRepository
    private let profiles: ProfileRepository
    private let admin: AdminRepository?

    public init(repository: ChatRepository,
                profiles: ProfileRepository,
                admin: AdminRepository? = nil) {
        self.repository = repository
        self.profiles = profiles
        self.admin = admin
    }

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
            if currentUserID == nil {
                let me = try await profiles.currentProfile()
                currentUserID = me.id
                isAdmin = me.role.isAdmin
            }
            threads = try await repository.loadThreads()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func detailModel(for thread: ChatThread) -> ThreadDetailViewModel? {
        guard let currentUserID else { return nil }
        return ThreadDetailViewModel(thread: thread, currentUserID: currentUserID,
                                     repository: repository)
    }

    /// The composer button. An apporteur has exactly one person to write to and
    /// should not be asked to pick; an admin picks from the members list.
    @MainActor
    public func startConversation(with contact: MemberOverview? = nil) async -> ChatThread? {
        do {
            let id: UUID
            if let contact {
                id = try await repository.startDirectThread(with: contact.id)
            } else {
                id = try await repository.startSupportThread()
            }
            threads = try await repository.loadThreads()
            errorMessage = nil
            return threads.first { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @MainActor
    public func loadContacts() async {
        guard isAdmin, contacts.isEmpty, let admin else { return }
        contacts = ((try? await admin.members()) ?? []).filter { $0.isActive }
    }

    @MainActor
    public func setPinned(_ pinned: Bool, on thread: ChatThread) async {
        await apply(pinned: pinned, archived: nil, to: thread)
    }

    @MainActor
    public func setArchived(_ archived: Bool, on thread: ChatThread) async {
        await apply(pinned: nil, archived: archived, to: thread)
    }

    /// Applied locally first so the row moves under the finger, then reverted
    /// if the server disagrees.
    @MainActor
    private func apply(pinned: Bool?, archived: Bool?, to thread: ChatThread) async {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        let previous = threads[index]
        if let pinned { threads[index].pinned = pinned }
        if let archived { threads[index].archived = archived }
        do {
            try await repository.setFlags(threadID: thread.id, pinned: pinned, archived: archived)
        } catch {
            threads[index] = previous
            errorMessage = error.localizedDescription
        }
    }
}

public struct ChatView: View {
    @State private var model: ChatViewModel
    @State private var route: ChatThread?
    @State private var showsContacts = false

    public init(model: ChatViewModel) { _model = State(wrappedValue: model) }

    public var body: some View {
        NavigationStack {
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
                        Button { compose() } label: {
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

                    if let message = model.errorMessage {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                    }

                    if model.visibleThreads.isEmpty {
                        emptyState
                    } else {
                        list
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Spacing.gutter)
            }
            .navigationDestination(item: $route) { thread in
                if let detail = model.detailModel(for: thread) {
                    ThreadDetailView(model: detail)
                        .onDisappear { Task { await model.load() } }
                }
            }
            .sheet(isPresented: $showsContacts) {
                contactPicker
            }
        }
        .task {
            await model.load()
            await model.loadContacts()
        }
    }

    private var list: some View {
        List(model.visibleThreads) { thread in
            Button { route = thread } label: { ThreadRow(thread: thread) }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                .listRowSeparatorTint(Theme.Palette.hairline)
                .listRowBackground(Theme.Palette.canvas)
                .swipeActions(edge: .leading) {
                    Button {
                        Task { await model.setPinned(!thread.pinned, on: thread) }
                    } label: {
                        Label(thread.pinned ? "Détacher" : "Épingler",
                              systemImage: thread.pinned ? "pin.slash" : "pin")
                    }
                    .tint(Theme.Palette.brand)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        Task { await model.setArchived(!thread.archived, on: thread) }
                    } label: {
                        Label(thread.archived ? "Désarchiver" : "Archiver",
                              systemImage: "archivebox")
                    }
                    .tint(Theme.Palette.textSecondary)
                }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    /// An apporteur has one correspondent and is taken straight there; an admin
    /// has hundreds and is asked which.
    private func compose() {
        if model.isAdmin {
            showsContacts = true
        } else {
            Task { route = await model.startConversation() }
        }
    }

    private var contactPicker: some View {
        NavigationStack {
            List(model.contacts) { contact in
                Button {
                    showsContacts = false
                    Task { route = await model.startConversation(with: contact) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.fullName)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(contact.email)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Nouvelle discussion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { showsContacts = false }
                }
            }
        }
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
