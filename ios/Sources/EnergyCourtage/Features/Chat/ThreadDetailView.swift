import SwiftUI
import Observation

@Observable
public final class ThreadDetailViewModel {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var errorMessage: String?
    public var draft = ""
    public var isLoading = false

    private let thread: ChatThread
    private let currentUserID: UUID
    private let repository: ChatRepository

    public init(thread: ChatThread, currentUserID: UUID, repository: ChatRepository) {
        self.thread = thread
        self.currentUserID = currentUserID
        self.repository = repository
    }

    public var title: String { thread.displayName }

    public func isMine(_ message: ChatMessage) -> Bool { message.senderID == currentUserID }

    @MainActor
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await repository.loadMessages(threadID: thread.id)
            try? await repository.markRead(threadID: thread.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Optimistic send: the bubble appears immediately and is reconciled when
    /// the server answers. On failure it is rolled back and the text handed
    /// back to the composer, rather than vanishing with the message.
    @MainActor
    public func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""

        let pending = ChatMessage(id: UUID(), threadID: thread.id, senderID: currentUserID,
                                  senderName: "", body: body, createdAt: .now)
        messages.append(pending)

        do {
            let saved = try await repository.send(body: body, threadID: thread.id)
            if let index = messages.firstIndex(where: { $0.id == pending.id }) {
                messages[index] = saved
            }
        } catch {
            messages.removeAll { $0.id == pending.id }
            draft = body
            errorMessage = error.localizedDescription
        }
    }
}

public struct ThreadDetailView: View {
    @State private var model: ThreadDetailViewModel
    @FocusState private var composerFocused: Bool

    public init(model: ThreadDetailViewModel) {
        _model = State(wrappedValue: model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.s) {
                        ForEach(model.messages) { message in
                            MessageBubble(message: message, isMine: model.isMine(message))
                                .id(message.id)
                        }
                    }
                    .padding(Theme.Spacing.gutter)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.count) { _, _ in
                    withAnimation(.snappy) {
                        proxy.scrollTo(model.messages.last?.id, anchor: .bottom)
                    }
                }
            }

            if let message = model.errorMessage {
                Text(message)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.destructive)
                    .padding(.horizontal, Theme.Spacing.gutter)
            }

            composer
        }
        .background(Theme.Palette.canvas)
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.m) {
            TextField("Message", text: $model.draft, axis: .vertical)
                .font(Theme.Typography.body)
                .lineLimit(1...5)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.Palette.track)
                )
                .focused($composerFocused)

            Button { Task { await model.send() } } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(
                        model.draft.trimmingCharacters(in: .whitespaces).isEmpty
                            ? Theme.Palette.pendingRing : Theme.Palette.brand
                    ))
            }
            .buttonStyle(.plain)
            .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel(Strings.Actions.send)
        }
        .padding(Theme.Spacing.m)
        .background(Theme.Palette.surface)
        .overlay(alignment: .top) { Divider() }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 56) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                Text(message.body ?? "")
                    .font(Theme.Typography.body)
                    .foregroundStyle(isMine ? .white : Theme.Palette.textPrimary)
                Text(Self.time.string(from: message.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(isMine ? .white.opacity(0.75) : Theme.Palette.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isMine ? Theme.Palette.brand : Theme.Palette.track)
            )

            if !isMine { Spacer(minLength: 56) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isMine ? "Vous" : message.senderName), \(message.body ?? "")")
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()
}
