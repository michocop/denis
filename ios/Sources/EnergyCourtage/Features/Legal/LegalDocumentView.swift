import SwiftUI
import Observation
import CryptoKit

/// Shows a legal document in full and records acceptance of the exact text.
///
/// The screen it replaces had a two-line summary and a button. Whatever that
/// recorded, it was not a mandate: self-billing needs a prior written mandate,
/// and consent to a document nobody was shown does not survive being
/// questioned. So the whole text is here, the accept button sits under it, and
/// what gets sent is the digest of the bytes actually rendered — the server
/// refuses anything else, the same way it refuses a signature on an invoice
/// whose hash does not match.
/// Which document a sheet shows. A wrapper because `.sheet(item:)` needs
/// something Identifiable, and the key is all there is to say.
public struct LegalDocumentKey: Identifiable, Hashable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

@Observable
public final class LegalViewModel {
    public private(set) var documents: [LegalDocument] = []
    public private(set) var errorMessage: String?
    /// Set after the first load, so "not published" can be told apart from
    /// "still loading" -- the screen used to spin forever on a document that
    /// had not been published yet.
    public private(set) var hasLoaded = false
    public var isWorking = false
    /// Documents accepted from this screen, counted so each acceptance that
    /// went through is answered with a vibration.
    public private(set) var acceptances = 0

    private let repository: LegalRepository
    public init(repository: LegalRepository) { self.repository = repository }

    public var mandate: LegalDocument? {
        documents.first { $0.key == "mandat_facturation" }
    }

    /// Anything published and not yet accepted by this reader. The mandate is
    /// the one with teeth — invoicing is refused without it — but the CGU and
    /// the privacy policy have to be presented too.
    public var outstanding: [LegalDocument] {
        documents.filter { !$0.accepted }
    }

    @MainActor
    public func load() async {
        do {
            documents = try await repository.documents()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Hashes what was displayed rather than trusting the `sha256` that came
    /// with the row: if the two disagree the text was altered in transit, and
    /// sending back the server's own hash would paper over exactly that.
    @MainActor
    public func accept(_ document: LegalDocument) async {
        isWorking = true
        defer { isWorking = false }

        let rendered = SHA256.hash(data: Data(document.body.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard rendered == document.sha256 else {
            errorMessage = "Le document affiché ne correspond pas à celui publié. "
                + "Réessayez ; si le problème persiste, contactez Trinity Énergie."
            return
        }

        do {
            try await repository.accept(key: document.key, sha256: rendered)
            acceptances += 1
            await load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct LegalDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: LegalViewModel
    @State private var hasReadToEnd = false
    private let documentKey: String
    /// Shown because the person has to accept it before going on, rather than
    /// because they asked to read it: there is no "Fermer" while the document
    /// is there to be accepted.
    private let isRequired: Bool

    public init(model: LegalViewModel, documentKey: String, isRequired: Bool = false) {
        _model = State(wrappedValue: model)
        self.documentKey = documentKey
        self.isRequired = isRequired
    }

    private var document: LegalDocument? {
        model.documents.first { $0.key == documentKey }
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                BrandBackground()

                if let document {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                                LegalText(document.body)
                                    .textSelection(.enabled)

                                Text("Version \(document.version)")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)

                                // Marks the bottom. Reaching it enables the
                                // button: agreeing to a contract you have not
                                // scrolled through is the thing this screen
                                // exists to stop.
                                Color.clear.frame(height: 1)
                                    .onAppear { hasReadToEnd = true }
                            }
                            .padding(Theme.Spacing.gutter)
                        }

                        footer(document)
                    }
                } else if let message = model.errorMessage {
                    Text(message)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.destructive)
                        .padding(Theme.Spacing.gutter)
                } else if model.hasLoaded {
                    Text("Ce document n'est pas encore publié.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(Theme.Spacing.gutter)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(document?.title ?? "Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isRequired || document == nil || document?.accepted == true {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fermer") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isRequired && document?.accepted == false)
        .feedback(.success, trigger: model.acceptances)
        .errorFeedback(model.errorMessage)
        .task { await model.load() }
    }

    @ViewBuilder
    private func footer(_ document: LegalDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let message = model.errorMessage {
                Text(message)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if document.accepted {
                Label("Accepté", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.success)
            } else {
                if !hasReadToEnd {
                    Text("Faites défiler jusqu'à la fin pour accepter.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                PrimaryActionButton(model.isWorking ? "Enregistrement…" : "J'accepte") {
                    Task {
                        await model.accept(document)
                        if model.documents.first(where: { $0.key == documentKey })?.accepted == true {
                            dismiss()
                        }
                    }
                }
                .disabled(model.isWorking || !hasReadToEnd)
            }
        }
        .padding(Theme.Spacing.gutter)
        .background(Theme.Palette.surface)
        .overlay(alignment: .top) { Divider() }
    }
}


/// The legal texts are written in a little Markdown: "## " headings, "- "
/// lists and **bold**. Shown raw, a contract read "## Article 1 — Objet".
struct LegalText: View {
    enum Block: Hashable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    private let blocks: [Block]
    init(_ markdown: String) { blocks = Self.parse(markdown) }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.range(of: #"^Article \d+\b"#, options: .regularExpression) != nil,
                      line.count < 80 {
                // texts written before the Markdown: "Article 3 — Durée" alone on its line
                flush()
                blocks.append(.heading(line))
            } else if line.hasPrefix("- ") || line.hasPrefix("• ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(inline(text))
                        .font(Theme.Typography.display(18, .semibold, relativeTo: .title3))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.top, Theme.Spacing.s)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(Theme.Palette.brand).frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
                        Text(inline(text))
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                case .paragraph(let text):
                    Text(inline(text))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineSpacing(3)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
