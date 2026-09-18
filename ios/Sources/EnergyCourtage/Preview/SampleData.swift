import Foundation

/// Fixtures transcribed from the source app's screenshots, so the previews
/// reproduce the two reference states exactly: the completed Thomas Dubois
/// card, and the same card mid-pipeline.
public enum SampleData {

    public static let stages: [Stage] = {
        let banner = "Contrat signé. Disponible dans l'onglet Documents"
        return [
            Stage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                  key: "a_contacter", label: "À contacter", position: 1),
            Stage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                  key: "rdv_programme", label: "RDV programmé", position: 2),
            Stage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                  key: "proposition_envoyee", label: "Proposition envoyée", position: 3),
            Stage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                  key: "devis_signe", label: "Devis signé", position: 4,
                  isRewardTrigger: true, bannerTemplate: banner),
            Stage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                  key: "mission_terminee", label: "Mission terminée", position: 5,
                  isTerminal: true, bannerTemplate: banner)
        ]
    }()

    public static let comments: [String: String] = [
        "a_contacter": "Merci pour la mise en relation. Nous avons bien reçu les coordonnées de Thomas Dubois. Prochain point après le 1er échange.",
        "rdv_programme": "J'ai contacté Thomas Dubois. Le rendez-vous est planifié. Je vous tiens informé(e) de la suite.",
        "proposition_envoyee": "J'ai transmis à Thomas Dubois la proposition. Retour attendu très prochainement.",
        "devis_signe": "Thomas Dubois a signé le devis. Votre récompense est validée, nous revenons vers vous pour le règlement.",
        "mission_terminee": """
        Bonjour Johann,
        Je vous informe que nous allons procéder au paiement de vos honoraires. Vous recevrez votre gain très prochainement.
        N'oubliez pas de procéder à votre déclaration de revenu en fin d'année.
        Si vous êtes un apporteur d'affaire occasionnel, vous devez déclarer les sommes perçues au titre des bénéfices non commerciaux (BNC) via votre déclaration de revenus - CERFA 2042 C -
        Bonne journée.
        """
    ]

    private static func event(_ stageKey: String, minutesAgo: Int) -> StageEvent {
        let stage = stages.first { $0.key == stageKey }!
        return StageEvent(id: UUID(), stageID: stage.id, comment: comments[stageKey],
                          completedAt: Date().addingTimeInterval(-Double(minutesAgo) * 60))
    }

    /// Screenshot 1: every stage green, reward earned, contract available.
    public static var completedRecommendation: Recommendation {
        Recommendation(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            filleulFirstName: "Thomas", filleulLastName: "Dubois",
            filleulPhone: "+33 6 75 75 75 75",
            parrainName: "Johann Lefeuvre",
            createdAt: Date().addingTimeInterval(-60 * 60 * 8),
            currentStageID: stages[4].id,
            events: [
                event("a_contacter", minutesAgo: 480),
                event("rdv_programme", minutesAgo: 360),
                event("proposition_envoyee", minutesAgo: 240),
                event("devis_signe", minutesAgo: 120),
                event("mission_terminee", minutesAgo: 30)
            ],
            rewardAmount: 1000,
            rewardStatus: .invoiced,
            hasContract: true,
            invoiceNumber: "FA-2026-0001",
            invoiceID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            daysSinceActivity: 0,
            hasNote: true
        )
    }

    /// Screenshot 5: one stage done, one in progress, three ahead — and
    /// therefore no amount and no banner.
    public static var inProgressRecommendation: Recommendation {
        Recommendation(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            filleulFirstName: "Thomas", filleulLastName: "Dubois",
            filleulPhone: "+33 6 75 75 75 75",
            parrainName: "Johann Lefeuvre",
            createdAt: Date().addingTimeInterval(-60 * 60 * 8),
            currentStageID: stages[1].id,
            events: [event("a_contacter", minutesAgo: 60)],
            rewardAmount: 1000,
            rewardStatus: .pending,
            hasContract: false,
            // Deliberately stale, so the staleness banner has something to show.
            daysSinceActivity: 11
        )
    }
}

/// In-memory repository for previews, UI work and tests.
public struct PreviewRecommendationsRepository: RecommendationsRepository {
    private let items: [Recommendation]
    private let delay: Duration

    public init(items: [Recommendation] = [SampleData.completedRecommendation,
                                           SampleData.inProgressRecommendation],
                delay: Duration = .milliseconds(120)) {
        self.items = items
        self.delay = delay
    }

    public func loadPipeline() async throws -> [Stage] {
        try? await Task.sleep(for: delay)
        return SampleData.stages
    }

    public func loadPage(archived: Bool, search: String,
                         cursor: RecommendationCursor?) async throws -> [Recommendation] {
        try? await Task.sleep(for: delay)
        guard cursor == nil else { return [] }   // previews hold one page
        return items
            .filter { $0.status.isArchived == archived }
            .filter { search.isEmpty
                      || $0.filleulName.localizedCaseInsensitiveContains(search)
                      || $0.parrainName.localizedCaseInsensitiveContains(search) }
    }

    public func advanceStage(recommendationID: UUID, stageKey: String) async throws -> Recommendation {
        try? await Task.sleep(for: delay)
        guard var reco = items.first(where: { $0.id == recommendationID }),
              let stage = SampleData.stages.first(where: { $0.key == stageKey })
        else { throw PreviewError.notFound }

        reco.events.append(StageEvent(id: UUID(), stageID: stage.id,
                                      comment: SampleData.comments[stageKey],
                                      completedAt: .now))
        reco.currentStageID = stage.id
        if stage.isRewardTrigger, reco.rewardStatus == .pending { reco.rewardStatus = .earned }
        return reco
    }

    public func create(_ draft: RecommendationDraft) async throws -> Recommendation {
        try? await Task.sleep(for: delay)
        return Recommendation(
            id: UUID(),
            filleulFirstName: draft.firstName,
            filleulLastName: draft.lastName,
            filleulPhone: draft.phone,
            parrainName: "Johann Lefeuvre",
            createdAt: .now,
            currentStageID: SampleData.stages[0].id
        )
    }

    enum PreviewError: Error { case notFound }
}

// MARK: - Fakes for the other screens
//
// Enough behaviour to exercise the states each screen actually has, so a
// preview shows something real rather than an empty frame.

public struct PreviewCatalogueRepository: CatalogueRepository {
    public init() {}

    public func loadOffers() async throws -> [Offer] {
        try? await Task.sleep(for: .milliseconds(100))
        return [
            Offer(id: UUID(), title: "Suivi",
                  description: "Nous surveillons vos dates d'échéances pour vous afin de toujours entamer les négociations au meilleur moment",
                  position: 1),
            Offer(id: UUID(), title: "Optimisation",
                  description: "Nous vous trouvons le meilleur prix de molécule, optimisons les puissances de vos compteurs et analysons votre éligibilité à l'exonération de certaines taxes",
                  position: 2),
            Offer(id: UUID(), title: "Conseil",
                  description: "Suite à l'audit de votre situation, nous vous présentons les solutions les plus adaptées",
                  position: 3)
        ]
    }

    public func save(_ offer: Offer) async throws -> Offer { offer }
    public func delete(offerID: UUID) async throws {}
}

public struct PreviewChatRepository: ChatRepository {
    public init() {}

    public func loadThreads() async throws -> [ChatThread] {
        try? await Task.sleep(for: .milliseconds(100))
        return [
            ChatThread(id: UUID(), kind: .direct, counterpartName: "Johann Lefeuvre",
                       lastMessage: "Bonjour, une question sur Thomas Dubois.",
                       lastMessageAt: .now, unreadCount: 2),
            ChatThread(id: UUID(), kind: .direct, counterpartName: "Marie Durand",
                       lastMessage: "Merci !",
                       lastMessageAt: .now.addingTimeInterval(-7200), pinned: true),
            ChatThread(id: UUID(), kind: .ticket, title: "Problème de virement",
                       counterpartName: "Support",
                       lastMessage: "Je n'ai pas reçu mon paiement.",
                       lastMessageAt: .now.addingTimeInterval(-86_400))
        ]
    }

    public func loadMessages(threadID: UUID) async throws -> [ChatMessage] {
        let me = UUID()
        return [
            ChatMessage(id: UUID(), threadID: threadID, senderID: UUID(),
                        senderName: "Johann Lefeuvre",
                        body: "Bonjour, une question sur Thomas Dubois.",
                        createdAt: .now.addingTimeInterval(-3600)),
            ChatMessage(id: UUID(), threadID: threadID, senderID: me,
                        senderName: "Vous",
                        body: "Bien sûr, je vous écoute.",
                        createdAt: .now.addingTimeInterval(-3400))
        ]
    }

    public func send(body: String, threadID: UUID) async throws -> ChatMessage {
        ChatMessage(id: UUID(), threadID: threadID, senderID: UUID(),
                    senderName: "Vous", body: body, createdAt: .now)
    }

    public func markRead(threadID: UUID) async throws {}
    public func openTicket(subject: String, body: String) async throws -> UUID { UUID() }
}

public struct PreviewProfileRepository: ProfileRepository {
    /// Drives the mandate notice on Accueil, which only appears when one is
    /// missing — the state worth seeing in a preview.
    private let hasMandate: Bool
    public init(hasMandate: Bool = false) { self.hasMandate = hasMandate }

    public func currentProfile() async throws -> Profile {
        Profile(id: UUID(), role: .apporteur, firstName: "Johann", lastName: "Lefeuvre",
                email: "johann@example.test", companyName: "Lefeuvre Conseil",
                city: "Lille",
                billingMandateSignedAt: hasMandate ? .now.addingTimeInterval(-86_400 * 90) : nil)
    }

    public func save(_ profile: Profile) async throws -> Profile { profile }

    public func dashboardStats() async throws -> DashboardStats {
        try? await Task.sleep(for: .milliseconds(100))
        return DashboardStats(activeCount: 3, archivedCount: 1, pendingTotal: 1500,
                              earnedTotal: 1300, paidTotal: 300, conversionRate: 25)
    }

    public func signBillingMandate() async throws -> Profile {
        try await PreviewProfileRepository(hasMandate: true).currentProfile()
    }

    public func deleteAccount() async throws {}
}

public struct PreviewInvoiceRepository: InvoiceRepository {
    public init() {}

    public func document(invoiceID: UUID) async throws -> InvoiceDocument {
        InvoiceDocument(
            number: "FA-2026-0001",
            documentSha256: String(repeating: "a", count: 64),
            issuer: .init(name: "Pierre-Louis Tettamanti", company: "Trinity Énergie",
                          city: "AIX-EN-PEVELE", siret: nil),
            apporteur: .init(name: "Johann Lefeuvre", company: "Lefeuvre Conseil",
                             city: nil, siret: "12345678900011"),
            attestation: .init(soussigne: "Johann Lefeuvre",
                               misEnRelation: "Trinity Énergie",
                               avec: "Thomas Dubois",
                               prestation: "Apport d'affaires - mise en relation",
                               intervenueLe: "17.09.2026"),
            amount: .init(ht: "300.00", vatRate: 0, vat: "0.00", ttc: "300.00",
                          currency: "EUR"),
            legalMentions: "TVA non applicable – Régime d'exonération de TVA (Article 293B du Code général des impôts)",
            paymentMethod: "Virement bancaire",
            place: "AIX-EN-PEVELE",
            issuedOn: "17.09.2026",
            taxNotice: "N'oubliez pas de procéder à votre déclaration de revenu en fin d'année.",
            status: "awaiting_signatures",
            signatures: [
                .init(role: "apporteur", name: "Johann Lefeuvre", signed: true,
                      signedAt: .now),
                .init(role: "entreprise", name: "Pierre-Louis Tettamanti", signed: false,
                      signedAt: nil)
            ]
        )
    }

    public func latestInvoiceID(recommendationID: UUID) async throws -> UUID? { UUID() }
    public func sign(invoiceID: UUID, documentSHA256: String) async throws {}
}

public struct PreviewRemindersRepository: RemindersRepository {
    public init() {}

    public func reminders(recommendationID: UUID) async throws -> [Reminder] {
        [
            Reminder(id: UUID(), label: "Relancer Thomas Dubois",
                     dueAt: .now.addingTimeInterval(86_400), status: .scheduled),
            Reminder(id: UUID(), label: "Envoyer la proposition",
                     dueAt: .now.addingTimeInterval(-86_400), status: .scheduled)
        ]
    }

    public func schedule(recommendationID: UUID, label: String, dueAt: Date) async throws -> Reminder {
        Reminder(id: UUID(), label: label, dueAt: dueAt, status: .scheduled)
    }

    public func complete(reminderID: UUID) async throws {}
}

public struct PreviewAdminRepository: AdminRepository {
    public init() {}

    public func members() async throws -> [MemberOverview] {
        try? await Task.sleep(for: .milliseconds(100))
        return [
            MemberOverview(id: UUID(), fullName: "Johann Lefeuvre",
                           email: "johann@example.test", phone: "+33 6 11 11 11 11",
                           role: .apporteur, status: "active", vatLiable: false,
                           hasMandate: true, totalRecommendations: 18,
                           activeRecommendations: 4, paidTotal: 2300, owedTotal: 1000,
                           lastRecommendationAt: .now),
            MemberOverview(id: UUID(), fullName: "Marie Durand",
                           email: "marie@example.test", phone: nil,
                           role: .apporteur, status: "pending", vatLiable: false,
                           hasMandate: false, totalRecommendations: 0,
                           activeRecommendations: 0, paidTotal: 0, owedTotal: 0,
                           lastRecommendationAt: nil),
            MemberOverview(id: UUID(), fullName: "Paul Riviere",
                           email: "paul@example.test", phone: nil,
                           role: .apporteur, status: "active", vatLiable: true,
                           hasMandate: true, totalRecommendations: 0,
                           activeRecommendations: 0, paidTotal: 0, owedTotal: 0,
                           lastRecommendationAt: nil)
        ]
    }

    public func setStatus(profileID: UUID, status: String) async throws {}
    public func approve(profileID: UUID) async throws {}

    public func createInvite(email: String?, role: UserRole,
                             autoActivate: Bool) async throws -> Invite {
        Invite(code: "K7M2QXPZ", email: email, role: role,
               autoActivate: autoActivate, expiresAt: .now.addingTimeInterval(30 * 86_400))
    }

    public func payableInvoices() async throws -> [PayableInvoice] {
        try? await Task.sleep(for: .milliseconds(100))
        return [
            PayableInvoice(invoiceId: UUID(), number: "FA-2026-0004", issuedOn: .now,
                           amountTtc: 300, apporteurId: UUID(),
                           apporteurName: "Johann Lefeuvre", hasBankDetails: true,
                           recommendationId: UUID(), filleul: "Thomas Dubois"),
            PayableInvoice(invoiceId: UUID(), number: "FA-2026-0005", issuedOn: .now,
                           amountTtc: 750, apporteurId: UUID(),
                           apporteurName: "Johann Lefeuvre", hasBankDetails: true,
                           recommendationId: UUID(), filleul: "Claire Petit"),
            // Deliberately unpayable, so the blocked state is visible.
            PayableInvoice(invoiceId: UUID(), number: "FA-2026-0006", issuedOn: .now,
                           amountTtc: 500, apporteurId: UUID(),
                           apporteurName: "Paul Riviere", hasBankDetails: false,
                           recommendationId: UUID(), filleul: "Luc Martin")
        ]
    }

    public func payBatch(invoiceIDs: [UUID], reference: String?) async throws {}
}

public struct PreviewCommissionsRepository: CommissionsRepository {
    public init() {}

    public func statement(year: Int?) async throws -> [CommissionLine] {
        let thisYear = Calendar.current.component(.year, from: .now)
        return [
            CommissionLine(recommendationId: UUID(), year: thisYear, filleul: "Thomas Dubois",
                           rewardAmount: 1000, rewardStatus: .paid,
                           invoiceNumber: "FA-2026-0001", issuedOn: .now,
                           amountTtc: 1000, invoiceStatus: "paid"),
            CommissionLine(recommendationId: UUID(), year: thisYear, filleul: "Claire Petit",
                           rewardAmount: 300, rewardStatus: .invoiced,
                           invoiceNumber: "FA-2026-0002", issuedOn: .now,
                           amountTtc: 300, invoiceStatus: "signed"),
            CommissionLine(recommendationId: UUID(), year: thisYear, filleul: "Luc Martin",
                           rewardAmount: 750, rewardStatus: .earned,
                           invoiceNumber: nil, issuedOn: nil,
                           amountTtc: nil, invoiceStatus: nil)
        ]
    }

    public func notifications() async throws -> [AppNotification] {
        [
            AppNotification(id: UUID(), kind: "reward_earned",
                            payload: ["filleul": "Thomas Dubois", "stage_label": "Devis signé"],
                            readAt: nil, createdAt: .now),
            AppNotification(id: UUID(), kind: "payout_sent",
                            payload: ["invoice_number": "FA-2026-0001"],
                            readAt: nil, createdAt: .now.addingTimeInterval(-86_400))
        ]
    }

    public func markNotificationsRead() async throws {}
}
