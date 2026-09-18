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
@Observable
public final class LegalViewModel {
    public private(set) var documents: [LegalDocument] = []
    public private(set) var errorMessage: String?
    public var isWorking = false

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

    public init(model: LegalViewModel, documentKey: String) {
        _model = State(wrappedValue: model)
        self.documentKey = documentKey
    }

    private var document: LegalDocument? {
        model.documents.first { $0.key == documentKey }
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()

                if let document {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                                Text(document.body)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)

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
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(document?.title ?? "Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
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
