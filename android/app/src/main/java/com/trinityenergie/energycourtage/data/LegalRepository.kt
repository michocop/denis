package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.core.sha256Hex
import com.trinityenergie.energycourtage.model.LegalDocument
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.time.temporal.ChronoUnit

interface LegalRepository {
    /** Every published document, with whether this reader has accepted THIS
     *  version -- a revised mandate has to be signed again. */
    suspend fun documents(): List<LegalDocument>

    /** Sends back the digest of the text that was displayed. The server
     *  refuses a mismatch, so consent can only attach to what was shown. */
    suspend fun accept(key: String, sha256: String)
}

/** Reads `legal_documents_for_me`, which returns only published versions and
 *  says whether this reader has accepted each one. */
class SupabaseLegalRepository(private val client: SupabaseClient) : LegalRepository {
    override suspend fun documents(): List<LegalDocument> =
        client.decodeWith(ListSerializer(LegalDocument.serializer()), client.select("legal_documents_for_me", "order=key.asc"))

    override suspend fun accept(key: String, sha256: String) =
        client.rpcVoid("accept_legal_document", buildJsonObject {
            put("p_key", key)
            put("p_sha256", sha256)
        })
}

/** The demo's documents (iOS PreviewLegalRepository): the contract and the
 *  mandate, real enough that the scroll-to-the-end rule and the accept button
 *  can be tried. Acceptances are kept for the session. */
object DemoLegal : LegalRepository {
    private val lock = Mutex()
    private val accepted = mutableSetOf<String>()

    suspend fun markAccepted(key: String) = lock.withLock { accepted += key }
    suspend fun isAccepted(key: String) = lock.withLock { key in accepted }
    /** For tests, which share this object. */
    suspend fun reset() = lock.withLock { accepted.clear() }

    override suspend fun documents(): List<LegalDocument> {
        val published = Instant.now().minus(30, ChronoUnit.DAYS)
        return listOf(
            LegalDocument("contrat_apporteur", "demo-1", "Contrat d'apporteur d'affaires", DemoLegalTexts.contract,
                // the same digest the screen computes, so the demo exercises the check
                sha256Hex(DemoLegalTexts.contract), published, isAccepted("contrat_apporteur")),
            LegalDocument("mandat_facturation", "demo-1", "Mandat de facturation", DemoLegalTexts.mandate,
                sha256Hex(DemoLegalTexts.mandate), published, isAccepted("mandat_facturation")),
        )
    }

    override suspend fun accept(key: String, sha256: String) { markAccepted(key) }
}

fun Dependencies.legal(): LegalRepository = if (isDemo) DemoLegal else SupabaseLegalRepository(requireClient())

/** The texts of iOS Preview/SampleData.swift, byte for byte. */
internal object DemoLegalTexts {
    val contract = "**Entre les soussignés :**\n" +
        "\n" +
        "**TRINITY ENERGIE**, SAS au capital de 1 000 €, 945 rue du Général de Gaulle, 59310 Aix-en-Pévèle, RCS Lille Métropole 102 470 705, ci-après « la Société »,\n" +
        "\n" +
        "**Et** l'apporteur d'affaires titulaire du compte, ci-après « l'Apporteur ».\n" +
        "\n" +
        "## Article 1 — Objet\n" +
        "\n" +
        "Le présent contrat définit les conditions dans lesquelles l'Apporteur met la Société en relation avec des personnes susceptibles de lui confier le courtage de leurs contrats d'électricité et de gaz.\n" +
        "\n" +
        "## Article 2 — Mission de l'Apporteur\n" +
        "\n" +
        "- n'adresser que des personnes préalablement informées et d'accord ;\n" +
        "- transmettre des informations exactes, obtenues de manière licite ;\n" +
        "- ne jamais engager la Société ni se présenter comme son représentant.\n" +
        "\n" +
        "## Article 3 — Indépendance\n" +
        "\n" +
        "L'Apporteur exerce en toute indépendance. Le contrat ne crée ni lien de subordination, ni exclusivité.\n" +
        "\n" +
        "## Article 4 — Rémunération\n" +
        "\n" +
        "Une commission, fixée pour chaque recommandation et affichée dans l'application, est acquise à la signature du devis par la personne recommandée, et réglée sous 30 jours après la signature de la facture.\n" +
        "\n" +
        "## Article 5 — Facturation\n" +
        "\n" +
        "Les factures sont établies par la Société au nom de l'Apporteur, selon le mandat de facturation annexé.\n" +
        "\n" +
        "## Article 6 — Durée\n" +
        "\n" +
        "Durée indéterminée, résiliable par écrit avec un préavis de 30 jours.\n" +
        "\n" +
        "## Article 7 — Signature électronique\n" +
        "\n" +
        "La signature apposée via l'application, confirmée par un code reçu par SMS, vaut signature au sens des articles 1366 et 1367 du Code civil.\n" +
        "\n" +
        "— Données de démonstration, sans valeur contractuelle —"

    val mandate = "Entre les soussignés :\n" +
        "\n" +
        "TRINITY ENERGIE, SAS au capital de 1 000 €, dont le siège social est situé\n" +
        "945 rue du Général de Gaulle, 59310 Aix-en-Pévèle, immatriculée au RCS de\n" +
        "Lille Métropole sous le numéro 102 470 705, représentée par Pierre-Louis\n" +
        "Tettamanti, en qualité de Président,\n" +
        "\n" +
        "ci-après « le Mandataire »,\n" +
        "\n" +
        "Et : l'apporteur d'affaires titulaire du compte, ci-après « le Mandant ».\n" +
        "\n" +
        "Article 1 — Objet\n" +
        "\n" +
        "Le Mandant donne mandat au Mandataire d'établir, en son nom et pour son\n" +
        "compte, les factures correspondant aux commissions d'apport d'affaires qui\n" +
        "lui sont dues au titre des mises en relation qu'il réalise.\n" +
        "\n" +
        "Article 2 — Obligations du Mandataire\n" +
        "\n" +
        "Le Mandataire s'engage à établir les factures conformément aux mentions\n" +
        "obligatoires prévues par l'article 242 nonies A de l'annexe II au CGI, à\n" +
        "respecter une numérotation chronologique et continue, à mettre chaque\n" +
        "facture à disposition du Mandant préalablement à son émission définitive,\n" +
        "et à en conserver un double pendant dix ans.\n" +
        "\n" +
        "Article 3 — Obligations du Mandant\n" +
        "\n" +
        "Le Mandant s'engage à signaler sans délai tout changement de sa situation,\n" +
        "notamment le passage à un régime assujetti à la TVA, à vérifier chaque\n" +
        "facture établie en son nom, et à procéder lui-même aux déclarations\n" +
        "fiscales et sociales qui lui incombent.\n" +
        "\n" +
        "Article 4 — Régime de TVA\n" +
        "\n" +
        "Le régime de TVA applicable est celui que le Mandant déclare dans son profil :\n" +
        "franchise en base (article 293 B du CGI) ou régime réel, avec son numéro de TVA\n" +
        "intracommunautaire. Il figure sur chaque facture. Tout changement de régime\n" +
        "doit être signalé sans délai ; les factures ultérieures seront établies en\n" +
        "conséquence.\n" +
        "\n" +
        "Article 5 — Absence de lien de subordination\n" +
        "\n" +
        "Le Mandant exerce son activité en toute indépendance. Le présent mandat ne\n" +
        "crée ni lien de subordination, ni exclusivité, ni obligation de résultat.\n" +
        "\n" +
        "Article 6 — Durée et résiliation\n" +
        "\n" +
        "Le présent mandat prend effet à la date de sa signature et est conclu pour une\n" +
        "durée indéterminée. Chaque partie peut y mettre fin à tout moment moyennant un\n" +
        "préavis de 30 jours notifié par écrit. Les factures établies avant la\n" +
        "résiliation demeurent valables.\n" +
        "\n" +
        "Article 7 — Signature électronique\n" +
        "\n" +
        "Les parties conviennent que la signature électronique apposée via\n" +
        "l'application constitue une signature au sens de l'article 1367 du Code\n" +
        "civil et vaut preuve de leur consentement.\n" +
        "\n" +
        "— Données de démonstration, sans valeur contractuelle —"
}
