import Foundation

public protocol ChatRepository: Sendable {
    func loadThreads() async throws -> [ChatThread]
    func loadMessages(threadID: UUID) async throws -> [ChatMessage]
    func send(body: String, threadID: UUID) async throws -> ChatMessage
    func markRead(threadID: UUID) async throws
    func openTicket(subject: String, body: String) async throws -> UUID
    /// Returns the thread id, creating it only if it does not already exist:
    /// the apporteur does not know which administrator to write to.
    func startSupportThread() async throws -> UUID
    func startDirectThread(with profileID: UUID) async throws -> UUID
    /// Pinning and archiving are per reader, not per thread.
    func setFlags(threadID: UUID, pinned: Bool?, archived: Bool?) async throws
}

public protocol ProfileRepository: Sendable {
    func currentProfile() async throws -> Profile
    func save(_ profile: Profile) async throws -> Profile
    func dashboardStats() async throws -> DashboardStats
    func deleteAccount() async throws
}

public protocol InvoiceRepository: Sendable {
    func document(invoiceID: UUID) async throws -> InvoiceDocument
    func latestInvoiceID(recommendationID: UUID) async throws -> UUID?
    func sign(invoiceID: UUID, documentSHA256: String) async throws
    /// Sends the signature code by SMS. `required == false` means SMS is not
    /// set up on the server, and signing goes ahead without one.
    func requestSignatureCode(invoiceID: UUID) async throws -> SignatureCodeRequest
    /// Checks the code. A wrong one is counted server-side, so this never
    /// throws for it: the result says what happened.
    func verifySignatureCode(invoiceID: UUID, code: String) async throws -> SignatureCodeCheck
    /// The PDF that is legally retained. Returns the stored file if one exists
    /// and otherwise renders, uploads and records it — so the document kept
    /// for ten years is written exactly once.
    func pdf(for document: InvoiceDocument, invoiceID: UUID) async throws -> Data
    /// Issues the invoice for an earned commission. The amount comes from the
    /// recommendation, never from the caller.
    func issue(recommendationID: UUID) async throws -> UUID
    /// The only lawful correction to a signed invoice: a new document in the
    /// same series carrying the negative amount.
    func createCreditNote(invoiceID: UUID, reason: String) async throws -> UUID
}

/// What a signer is told after asking for a code.
public struct SignatureCodeRequest: Decodable, Hashable, Identifiable, Sendable {
    public var id: String { sentTo ?? "code" }
    public let required: Bool
    /// "06 •• •• •• 78": enough to recognise the phone, not enough to read it.
    public let sentTo: String?

    public init(required: Bool, sentTo: String? = nil) {
        self.required = required; self.sentTo = sentTo
    }
}

/// The verdict on a typed code.
public struct SignatureCodeCheck: Decodable, Hashable, Sendable {
    public enum Result: String, Decodable, Sendable {
        case verified, wrong, expired, locked, none
    }
    public let result: Result
    public let remaining: Int?

    public init(result: Result, remaining: Int? = nil) {
        self.result = result; self.remaining = remaining
    }
}

/// Fakes that predate the SMS step sign straight away, as a project with no
/// SMS sender configured does.
public extension InvoiceRepository {
    func requestSignatureCode(invoiceID: UUID) async throws -> SignatureCodeRequest {
        SignatureCodeRequest(required: false)
    }
    func verifySignatureCode(invoiceID: UUID, code: String) async throws -> SignatureCodeCheck {
        SignatureCodeCheck(result: .verified)
    }
}

/// Everything a screen needs, resolved once at launch and handed down through
/// the environment. Concrete types stay behind the protocols so any screen can
/// be previewed against fakes.
public struct Dependencies: Sendable {
    public let recommendations: RecommendationsRepository
    public let chat: ChatRepository
    public let profiles: ProfileRepository
    public let invoices: InvoiceRepository
    public let reminders: RemindersRepository
    public let admin: AdminRepository
    public let commissions: CommissionsRepository
    public let notifications: NotificationsRepository
    public let legal: LegalRepository
    public let changeMonitor: ChangeMonitor

    public init(recommendations: RecommendationsRepository,
                chat: ChatRepository,
                profiles: ProfileRepository,
                invoices: InvoiceRepository,
                reminders: RemindersRepository,
                admin: AdminRepository,
                commissions: CommissionsRepository,
                notifications: NotificationsRepository,
                legal: LegalRepository,
                changeMonitor: ChangeMonitor = InertChangeMonitor()) {
        self.recommendations = recommendations
        self.chat = chat
        self.profiles = profiles
        self.invoices = invoices
        self.reminders = reminders
        self.admin = admin
        self.commissions = commissions
        self.notifications = notifications
        self.legal = legal
        self.changeMonitor = changeMonitor
    }
}
