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
            invoiceNumber: "FA-2026-0001"
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
            hasContract: false
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

    public func loadRecommendations(archived: Bool) async throws -> [Recommendation] {
        try? await Task.sleep(for: delay)
        return items.filter { $0.status.isArchived == archived }
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

    enum PreviewError: Error { case notFound }
}
