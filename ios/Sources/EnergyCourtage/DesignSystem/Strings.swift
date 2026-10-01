import Foundation

/// Every user-facing string in one place.
///
/// The product is French and ships French, but the copy is the part most
/// likely to be reworded by the business, and centralising it means a change
/// of wording is never a hunt through views. It is also what makes a second
/// language a translation job rather than a refactor.
public enum Strings {

    public enum Reco {
        public static let title           = "Recommandations"
        public static let active          = "Actives"
        public static let archived        = "Archivées"
        public static let search          = "Rechercher..."
        public static let recommendedBy   = "Recommandé par"
        public static let personalNotes   = "Notes personnelles"
        public static let viewContract    = "Voir le contrat"
        public static let viewMore        = "Voir plus"
        public static let validateStage   = "Valider l'étape"
        public static let newItems        = "De nouveaux éléments sont disponibles"
        public static let refresh         = "Actualiser"
        public static let reward          = "Récompense"
        public static let emptyActive     = "Aucune recommandation active"
        public static let emptyArchived   = "Aucune recommandation archivée"
        public static let emptySubtitle   = "Vos recommandations apparaîtront ici dès leur création."
        public static let noResults       = "Aucun résultat"
        public static let noResultsHint   = "Essayez un autre nom."

        public static func stageComment(_ stage: String) -> String {
            "Commentaire pour l'étape \"\(stage)\""
        }
        public static func idleFor(_ days: Int) -> String {
            days <= 1 ? "Mise à jour aujourd'hui" : "Sans activité depuis \(days) jours"
        }
    }

    public enum Actions {
        public static let close    = "Fermer"
        public static let cancel   = "Annuler"
        public static let next     = "Suivant"
        public static let save     = "Enregistrer"
        public static let retry    = "Réessayer"
        public static let send     = "Envoyer"
        public static let reassign = "Réassigner"
        public static let reminders = "Rappels"
        public static let reset    = "Remettre à zéro"
        public static let archive  = "Archiver"
        public static let delete   = "Supprimer"
    }

    public enum Duplicate {
        public static let alreadyYours =
            "Vous avez déjà recommandé cette personne. Retrouvez-la dans vos recommandations actives."
        public static let heldByAnother =
            "Cette personne est déjà suivie par une autre recommandation en cours. Vous pouvez envoyer la vôtre, mais la récompense reviendra à la première mise en relation."
    }

    public enum Errors {
        public static let generic   = "Une erreur est survenue. Réessayez dans un instant."
        public static let offline   = "Vous semblez hors ligne."
        public static let loadFailed = "Chargement impossible"
    }
}
