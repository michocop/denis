import Foundation
import CryptoKit

// MARK: - Recommendations

/// Reads through `recommendation_feed`, which returns a card and its whole
/// timeline in one row, and writes through the RPCs — so the client never
/// encodes an ordering rule the database already owns.
public struct SupabaseRecommendationsRepository: RecommendationsRepository {

    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    private struct FeedRow: Decodable {
        struct Event: Decodable {
            let stageKey: String
            let comment: String?
            let completedAt: Date
        }
        let id: UUID
        let filleulFirstName: String
        let filleulLastName: String
        let filleulPhone: String?
        let parrainName: String
        let createdAt: Date
        let currentStageKey: String
        let rewardStatus: RewardStatus
        let status: RecommendationStatus
        let displayedAmount: Decimal?
        let rewardAmount: Decimal?
        let events: [Event]
        let hasContract: Bool
        let invoiceNumber: String?
        let invoiceId: UUID?
        let daysSinceActivity: Int
        let hasNote: Bool
        let pendingReminders: Int
    }

    public func loadPipeline() async throws -> [Stage] {
        let rows: [StageRow] = try await client.get(
            "stages", query: [URLQueryItem(name: "order", value: "position.asc")]
        )
        return rows.map(\.asStage)
    }

    private struct StageRow: Decodable {
        let id: UUID
        let key: String
        let label: String
        let position: Int
        let isRewardTrigger: Bool
        let isTerminal: Bool
        let bannerTemplate: String?
        let commentTemplate: String?

        var asStage: Stage {
            Stage(id: id, key: key, label: label, position: position,
                  isRewardTrigger: isRewardTrigger, isTerminal: isTerminal,
                  bannerTemplate: bannerTemplate, commentTemplate: commentTemplate)
        }
    }

    public func loadPage(archived: Bool, search: String,
                         cursor: RecommendationCursor?) async throws -> [Recommendation] {
        let pipeline = try await loadPipeline()
        // Paging and searching both happen in one RPC, because the index that
        // makes search fast lives on the base table, not on the view.
        var body: [String: AnyEncodable] = [
            "p_archived": AnyEncodable(archived),
            "p_limit": AnyEncodable(20)
        ]
        if !search.isEmpty { body["p_search"] = AnyEncodable(search) }
        if let cursor {
            body["p_cursor_at"] = AnyEncodable(ISO8601DateFormatter().string(from: cursor.createdAt))
            body["p_cursor_id"] = AnyEncodable(cursor.id.uuidString)
        }
        let rows: [FeedRow] = try await client.rpc("recommendation_page", body: body)
        return rows.map { row in map(row, pipeline: pipeline) }
    }

    private func map(_ row: FeedRow, pipeline: [Stage]) -> Recommendation {
        let byKey = Dictionary(uniqueKeysWithValues: pipeline.map { ($0.key, $0) })
        return Recommendation(
            id: row.id,
            filleulFirstName: row.filleulFirstName,
            filleulLastName: row.filleulLastName,
            filleulPhone: row.filleulPhone,
            parrainName: row.parrainName,
            createdAt: row.createdAt,
            currentStageID: byKey[row.currentStageKey]?.id ?? UUID(),
            events: row.events.compactMap { event in
                guard let stage = byKey[event.stageKey] else { return nil }
                return StageEvent(id: UUID(), stageID: stage.id,
                                  comment: event.comment, completedAt: event.completedAt)
            },
            rewardAmount: row.rewardAmount,
            rewardStatus: row.rewardStatus,
            status: row.status,
            hasContract: row.hasContract,
            invoiceNumber: row.invoiceNumber,
            invoiceID: row.invoiceId,
            daysSinceActivity: row.daysSinceActivity,
            hasNote: row.hasNote,
            pendingReminders: row.pendingReminders
        )
    }

    public func advanceStage(recommendationID: UUID, stageKey: String) async throws -> Recommendation {
        // The RPC returns the raw row; re-read the feed so the caller gets the
        // same shape the list renders, timeline included.
        try await client.rpcVoid("advance_stage", body: [
            "p_recommendation_id": AnyEncodable(recommendationID.uuidString),
            "p_stage_key": AnyEncodable(stageKey)
        ])
        return try await reload(recommendationID)
    }

    private func reload(_ id: UUID) async throws -> Recommendation {
        let pipeline = try await loadPipeline()
        let rows: [FeedRow] = try await client.get("recommendation_feed", query: [
            URLQueryItem(name: "id", value: "eq.\(id.uuidString)")
        ])
        guard let row = rows.first else { throw SupabaseError.decoding("recommendation missing") }
        return map(row, pipeline: pipeline)
    }

    public func create(_ draft: RecommendationDraft) async throws -> Recommendation {
        // current_stage_id is left out on purpose: a trigger sets the entry
        // stage, so the form does not have to know the pipeline.
        var values: [String: AnyEncodable] = [
            "filleul_first_name": AnyEncodable(draft.firstName),
            "filleul_last_name": AnyEncodable(draft.lastName),
            "parrain_id": AnyEncodable(try await currentUserID().uuidString)
        ]
        if !draft.phone.isEmpty { values["filleul_phone"] = AnyEncodable(draft.phone) }
        if !draft.email.isEmpty { values["filleul_email"] = AnyEncodable(draft.email) }
        if !draft.company.isEmpty { values["filleul_company"] = AnyEncodable(draft.company) }

        struct Created: Decodable { let id: UUID }
        let created: [Created] = try await client.insert("recommendations", values: values)
        guard let id = created.first?.id else {
            throw SupabaseError.decoding("insert returned no row")
        }
        return try await reload(id)
    }

    public func reassign(recommendationID: UUID, to adminID: UUID) async throws {
        try await client.rpcVoid("reassign_recommendation", body: [
            "p_recommendation_id": AnyEncodable(recommendationID.uuidString),
            "p_admin_id": AnyEncodable(adminID.uuidString)
        ])
    }

    public func archive(recommendationID: UUID, won: Bool) async throws {
        try await client.rpcVoid("archive_recommendation", body: [
            "p_recommendation_id": AnyEncodable(recommendationID.uuidString),
            "p_won": AnyEncodable(won)
        ])
    }

    public func resetPipeline(recommendationID: UUID) async throws {
        try await client.rpcVoid("reset_pipeline", body: [
            "p_recommendation_id": AnyEncodable(recommendationID.uuidString)
        ])
    }

    public func softDelete(recommendationID: UUID) async throws {
        try await client.rpcVoid("soft_delete_recommendation", body: [
            "p_recommendation_id": AnyEncodable(recommendationID.uuidString)
        ])
    }

    public func loadAdmins() async throws -> [Profile] {
        try await client.get("profiles", query: [
            URLQueryItem(name: "role", value: "in.(admin,manager)"),
            URLQueryItem(name: "status", value: "eq.active"),
            URLQueryItem(name: "order", value: "first_name.asc")
        ])
    }

    public func checkDuplicate(phone: String, email: String) async throws -> DuplicateCheck {
        try await client.rpc("check_duplicate_filleul", body: [
            "p_phone": AnyEncodable(phone),
            "p_email": AnyEncodable(email)
        ])
    }

    public func note(recommendationID: UUID) async throws -> String {
        struct Row: Decodable { let body: String }
        // RLS already scopes personal_notes to their author, so no filter on
        // the reader is needed -- or possible.
        let rows: [Row] = try await client.get("personal_notes", query: [
            URLQueryItem(name: "select", value: "body"),
            URLQueryItem(name: "recommendation_id", value: "eq.\(recommendationID.uuidString)"),
            URLQueryItem(name: "limit", value: "1")
        ])
        return rows.first?.body ?? ""
    }

    public func saveNote(recommendationID: UUID, body: String) async throws {
        let author = try await currentUserID()
        struct Row: Decodable { let id: UUID }
        // One note per reader per recommendation, so this is an upsert.
        var request: [String: AnyEncodable] = [
            "recommendation_id": AnyEncodable(recommendationID.uuidString),
            "author_id": AnyEncodable(author.uuidString),
            "body": AnyEncodable(body)
        ]
        request["updated_at"] = AnyEncodable(ISO8601DateFormatter().string(from: .now))
        let _: [Row] = try await client.upsert("personal_notes", values: request,
                                               onConflict: "recommendation_id,author_id")
    }

    private func currentUserID() async throws -> UUID {
        struct Me: Decodable { let id: UUID }
        let me: [Me] = try await client.get("profiles", query: [
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "limit", value: "1")
        ])
        guard let id = me.first?.id else { throw SupabaseError.unauthenticated }
        return id
    }
}

// MARK: - Reminders

public struct SupabaseRemindersRepository: RemindersRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func reminders(recommendationID: UUID) async throws -> [Reminder] {
        try await client.get("reminders", query: [
            URLQueryItem(name: "select", value: "id,label,due_at,status"),
            URLQueryItem(name: "recommendation_id", value: "eq.\(recommendationID.uuidString)"),
            URLQueryItem(name: "order", value: "due_at.asc")
        ])
    }

    public func schedule(recommendationID: UUID, label: String, dueAt: Date) async throws -> Reminder {
        try await client.rpc("schedule_reminder", body: [
            "p_recommendation_id": AnyEncodable(recommendationID.uuidString),
            "p_label": AnyEncodable(label),
            "p_due_at": AnyEncodable(ISO8601DateFormatter().string(from: dueAt))
        ])
    }

    public func complete(reminderID: UUID) async throws {
        try await client.rpcVoid("complete_reminder", body: [
            "p_reminder_id": AnyEncodable(reminderID.uuidString)
        ])
    }
}

// MARK: - Chat

public struct SupabaseChatRepository: ChatRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    /// Reads `thread_overview`, not `threads`: the raw table has no name on a
    /// direct conversation, no last message and no unread count, which is why
    /// the list used to render "Conversation / Aucun message" for every row.
    private struct ThreadRow: Decodable {
        let id: UUID
        let kind: ChatThread.Kind
        let title: String?
        let counterpartName: String
        let lastMessage: String?
        let lastMessageAt: Date?
        let unreadCount: Int
        let pinned: Bool
        let archived: Bool
    }

    public func loadThreads() async throws -> [ChatThread] {
        let rows: [ThreadRow] = try await client.get("thread_overview", query: [
            URLQueryItem(name: "order", value: "last_message_at.desc.nullslast")
        ])
        return rows.map {
            ChatThread(id: $0.id, kind: $0.kind, title: $0.title,
                       counterpartName: $0.counterpartName,
                       lastMessage: $0.lastMessage, lastMessageAt: $0.lastMessageAt,
                       unreadCount: $0.unreadCount, pinned: $0.pinned, archived: $0.archived)
        }
    }

    private struct MessageRow: Decodable {
        let id: UUID
        let threadId: UUID
        let senderId: UUID
        let senderName: String?
        let body: String?
        let createdAt: Date
    }

    public func loadMessages(threadID: UUID) async throws -> [ChatMessage] {
        let rows: [MessageRow] = try await client.get("message_feed", query: [
            URLQueryItem(name: "thread_id", value: "eq.\(threadID.uuidString)"),
            URLQueryItem(name: "order", value: "created_at.asc,id.asc")
        ])
        return rows.map(Self.message)
    }

    public func send(body: String, threadID: UUID) async throws -> ChatMessage {
        struct Me: Decodable { let id: UUID }
        let me: [Me] = try await client.get("profiles", query: [
            URLQueryItem(name: "select", value: "id"), URLQueryItem(name: "limit", value: "1")
        ])
        guard let sender = me.first?.id else { throw SupabaseError.unauthenticated }

        // The INSERT returns the messages row, which carries no sender name;
        // the name is resolved by message_feed on the next read. The composer
        // labels its own bubble "Vous" anyway.
        let rows: [MessageRow] = try await client.insert("messages", values: [
            "thread_id": AnyEncodable(threadID.uuidString),
            "sender_id": AnyEncodable(sender.uuidString),
            "body": AnyEncodable(body)
        ])
        guard let row = rows.first else { throw SupabaseError.decoding("no message returned") }
        return Self.message(row)
    }

    private static func message(_ row: MessageRow) -> ChatMessage {
        ChatMessage(id: row.id, threadID: row.threadId, senderID: row.senderId,
                    senderName: row.senderName ?? "", body: row.body,
                    createdAt: row.createdAt)
    }

    public func markRead(threadID: UUID) async throws {
        try await client.rpcVoid("mark_thread_read", body: [
            "p_thread_id": AnyEncodable(threadID.uuidString)
        ])
    }

    public func openTicket(subject: String, body: String) async throws -> UUID {
        try await client.rpc("open_ticket", body: [
            "p_subject": AnyEncodable(subject),
            "p_body": AnyEncodable(body)
        ])
    }

    /// An apporteur should not have to know which administrator to write to.
    public func startSupportThread() async throws -> UUID {
        try await client.rpc("start_support_thread")
    }

    public func startDirectThread(with profileID: UUID) async throws -> UUID {
        try await client.rpc("start_direct_thread", body: [
            "p_other_profile_id": AnyEncodable(profileID.uuidString)
        ])
    }

    public func setFlags(threadID: UUID, pinned: Bool?, archived: Bool?) async throws {
        var body: [String: AnyEncodable] = ["p_thread_id": AnyEncodable(threadID.uuidString)]
        if let pinned { body["p_pinned"] = AnyEncodable(pinned) }
        if let archived { body["p_archived"] = AnyEncodable(archived) }
        try await client.rpcVoid("set_thread_flags", body: body)
    }
}

// MARK: - Profile

public struct SupabaseProfileRepository: ProfileRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func currentProfile() async throws -> Profile {
        // RLS already restricts this to the caller's own row.
        let rows: [Profile] = try await client.get("profiles",
                                                   query: [URLQueryItem(name: "limit", value: "1")])
        guard let profile = rows.first else { throw SupabaseError.unauthenticated }
        return profile
    }

    public func save(_ profile: Profile) async throws -> Profile {
        let rows: [Profile] = try await client.update("profiles", values: [
            "first_name": AnyEncodable(profile.firstName),
            "last_name": AnyEncodable(profile.lastName),
            "phone": AnyEncodable(profile.phone ?? ""),
            "company_name": AnyEncodable(profile.companyName ?? ""),
            "siret": AnyEncodable(profile.siret ?? ""),
            "city": AnyEncodable(profile.city ?? "")
        ], match: [URLQueryItem(name: "id", value: "eq.\(profile.id.uuidString)")])
        return rows.first ?? profile
    }

    public func dashboardStats() async throws -> DashboardStats {
        try await client.rpc("dashboard_stats")
    }

    public func signBillingMandate() async throws -> Profile {
        let profile = try await currentProfile()
        let rows: [Profile] = try await client.update("profiles", values: [
            "billing_mandate_signed_at": AnyEncodable(ISO8601DateFormatter().string(from: .now))
        ], match: [URLQueryItem(name: "id", value: "eq.\(profile.id.uuidString)")])
        return rows.first ?? profile
    }

    public func deleteAccount() async throws {
        // App Store guideline 5.1.1(v): deletion must be reachable in-app.
        try await client.rpcVoid("request_account_deletion")
    }
}

// MARK: - Invoices

public struct SupabaseInvoiceRepository: InvoiceRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func document(invoiceID: UUID) async throws -> InvoiceDocument {
        try await client.rpc("invoice_document", body: [
            "p_invoice_id": AnyEncodable(invoiceID.uuidString)
        ])
    }

    public func latestInvoiceID(recommendationID: UUID) async throws -> UUID? {
        struct Row: Decodable { let id: UUID }
        let rows: [Row] = try await client.get("invoices", query: [
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "recommendation_id", value: "eq.\(recommendationID.uuidString)"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "1")
        ])
        return rows.first?.id
    }

    public func sign(invoiceID: UUID, documentSHA256: String) async throws {
        // The hash is checked server-side against the issued invoice, so a
        // client cannot sign anything other than what it was shown.
        try await client.rpcVoid("sign_invoice", body: [
            "p_invoice_id": AnyEncodable(invoiceID.uuidString),
            "p_document_sha256": AnyEncodable(documentSHA256)
        ])
    }

    /// Retention (art. 242 nonies A ann. II CGI) is about keeping the document
    /// that was issued, so the first PDF wins: if one is already on file it is
    /// downloaded, and a fresh rendering is never substituted for it.
    ///
    /// The upload races when two devices open the same invoice at once. The
    /// bucket refuses the second write and `record_invoice_pdf` hands back the
    /// path already kept, so the loser ends up reading the winner's file
    /// rather than seeing an error.
    public func pdf(for document: InvoiceDocument, invoiceID: UUID) async throws -> Data {
        if let path = document.pdfPath {
            return try await client.download(bucket: Self.bucket, path: path)
        }

        let data = InvoicePDF.render(document)
        let path = "\(invoiceID.uuidString.lowercased()).pdf"

        // An unsigned invoice has no retained document: it is still a draft,
        // and the screen offers the PDF only once both signatures are in.
        guard document.isFullySigned else { return data }

        do {
            try await client.upload(bucket: Self.bucket, path: path, data: data,
                                    contentType: "application/pdf")
        } catch SupabaseError.http(let status, _) where status == 409 {
            // Someone else got there first; fall through and read theirs.
        }

        struct Recorded: Decodable { let path: String }
        let kept: String = try await client.rpc("record_invoice_pdf", body: [
            "p_invoice_id": AnyEncodable(invoiceID.uuidString),
            "p_path": AnyEncodable(path),
            "p_sha256": AnyEncodable(Self.sha256(data))
        ])
        return kept == path ? data : try await client.download(bucket: Self.bucket, path: kept)
    }

    private static let bucket = "invoices"

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
