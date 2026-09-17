import Foundation

public protocol CatalogueRepository: Sendable {
    func loadOffers() async throws -> [Offer]
    func save(_ offer: Offer) async throws -> Offer
    func delete(offerID: UUID) async throws
}

public protocol ChatRepository: Sendable {
    func loadThreads() async throws -> [ChatThread]
    func loadMessages(threadID: UUID) async throws -> [ChatMessage]
    func send(body: String, threadID: UUID) async throws -> ChatMessage
    func markRead(threadID: UUID) async throws
    func openTicket(subject: String, body: String) async throws -> UUID
}

public protocol ProfileRepository: Sendable {
    func currentProfile() async throws -> Profile
    func save(_ profile: Profile) async throws -> Profile
    func dashboardStats() async throws -> DashboardStats
    /// Signing the self-billing mandate, without which no invoice can be issued.
    func signBillingMandate() async throws -> Profile
    func deleteAccount() async throws
}

public protocol InvoiceRepository: Sendable {
    func document(invoiceID: UUID) async throws -> InvoiceDocument
    func latestInvoiceID(recommendationID: UUID) async throws -> UUID?
    func sign(invoiceID: UUID, documentSHA256: String) async throws
}

/// Everything a screen needs, resolved once at launch and handed down through
/// the environment. Concrete types stay behind the protocols so any screen can
/// be previewed against fakes.
public struct Dependencies: Sendable {
    public let recommendations: RecommendationsRepository
    public let catalogue: CatalogueRepository
    public let chat: ChatRepository
    public let profiles: ProfileRepository
    public let invoices: InvoiceRepository

    public init(recommendations: RecommendationsRepository,
                catalogue: CatalogueRepository,
                chat: ChatRepository,
                profiles: ProfileRepository,
                invoices: InvoiceRepository) {
        self.recommendations = recommendations
        self.catalogue = catalogue
        self.chat = chat
        self.profiles = profiles
        self.invoices = invoices
    }
}
