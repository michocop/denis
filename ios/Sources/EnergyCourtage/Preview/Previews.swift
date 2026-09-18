#if DEBUG
import SwiftUI

private func previewDependencies() -> Dependencies {
    Dependencies(
        recommendations: PreviewRecommendationsRepository(),
        catalogue: PreviewCatalogueRepository(),
        chat: PreviewChatRepository(),
        profiles: PreviewProfileRepository(),
        invoices: PreviewInvoiceRepository(),
        reminders: PreviewRemindersRepository()
    )
}

#Preview("Recommandations — apporteur") {
    RecommendationsView(
        model: RecommendationsViewModel(
            repository: PreviewRecommendationsRepository(), role: .apporteur
        ),
        dependencies: previewDependencies(),
        signerName: "Johann Lefeuvre"
    )
}

#Preview("Recommandations — admin") {
    RecommendationsView(
        model: RecommendationsViewModel(
            repository: PreviewRecommendationsRepository(), role: .admin
        ),
        dependencies: previewDependencies(),
        signerName: "Pierre-Louis Tettamanti"
    )
}

#Preview("Catalogue — admin") {
    CatalogueView(model: CatalogueViewModel(repository: PreviewCatalogueRepository(),
                                            role: .admin))
}

#Preview("Chat") {
    ChatView(model: ChatViewModel(repository: PreviewChatRepository()))
}

#Preview("Accueil") {
    HomeView(model: HomeViewModel(profiles: PreviewProfileRepository())) {}
}

#Preview("Rappels") {
    RemindersView(recommendationID: UUID(), filleulName: "Thomas Dubois",
                  repository: PreviewRemindersRepository())
}

/// Reference state A — screenshot 1.
#Preview("Carte terminée") {
    ScrollView {
        RecommendationCard(
            recommendation: SampleData.completedRecommendation,
            pipeline: SampleData.stages,
            role: .admin,
            isExpanded: .constant(true),
            onComment: { _ in }, onNotes: {}, onContract: {}, onMore: {}, onValidate: {}
        )
        .padding(Theme.Spacing.gutter)
    }
}

/// Reference state B — screenshot 5: completed / current / pending together.
#Preview("Carte en cours") {
    ScrollView {
        RecommendationCard(
            recommendation: SampleData.inProgressRecommendation,
            pipeline: SampleData.stages,
            role: .admin,
            isExpanded: .constant(true),
            onComment: { _ in }, onNotes: {}, onContract: {}, onMore: {}, onValidate: {}
        )
        .padding(Theme.Spacing.gutter)
    }
}

#Preview("Commentaire d'étape") {
    StageCommentDialog(
        stageLabel: "À contacter",
        message: SampleData.comments["a_contacter"]!,
        onClose: {}
    )
}
#endif
