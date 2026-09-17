#if DEBUG
import SwiftUI

#Preview("Recommandations — apporteur") {
    RecommendationsView(
        model: RecommendationsViewModel(
            repository: PreviewRecommendationsRepository(), role: .apporteur
        )
    )
}

#Preview("Recommandations — admin") {
    RecommendationsView(
        model: RecommendationsViewModel(
            repository: PreviewRecommendationsRepository(), role: .admin
        )
    )
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
