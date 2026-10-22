package com.trinityenergie.energycourtage.recommendations

import com.trinityenergie.energycourtage.core.SupabaseJson
import com.trinityenergie.energycourtage.data.DemoSamples
import com.trinityenergie.energycourtage.model.DocumentUpload
import com.trinityenergie.energycourtage.model.DuplicateCheck
import com.trinityenergie.energycourtage.model.FeedRow
import com.trinityenergie.energycourtage.model.LeadDocument
import com.trinityenergie.energycourtage.model.RecoDates
import com.trinityenergie.energycourtage.model.RecoStrings
import com.trinityenergie.energycourtage.model.Recommendation
import com.trinityenergie.energycourtage.model.RecommendationDraft
import com.trinityenergie.energycourtage.model.RecommendationStatus
import com.trinityenergie.energycourtage.model.Reminder
import com.trinityenergie.energycourtage.model.RewardStatus
import com.trinityenergie.energycourtage.model.StageState
import com.trinityenergie.energycourtage.model.fileSize
import com.trinityenergie.energycourtage.model.stepperRows
import com.trinityenergie.energycourtage.ui.documents.DocumentSources
import com.trinityenergie.energycourtage.ui.recommendations.RecoAction
import com.trinityenergie.energycourtage.ui.recommendations.parseCommission
import kotlinx.serialization.decodeFromString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigDecimal
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime

class RecommendationLogicTest {
    private val stages = DemoSamples.stages
    private val inProgress = DemoSamples.inProgress()
    private val completed = DemoSamples.completed()

    @Test fun stepperStatesOnAnInProgressRecommendation() {
        val states = inProgress.stepperRows(stages).map { it.state }
        assertEquals(listOf(StageState.Completed, StageState.Current, StageState.Pending, StageState.Pending, StageState.Pending), states)
    }

    @Test fun everyStageIsCompletedOnAFinishedRecommendation() {
        assertTrue(completed.stepperRows(stages).all { it.state == StageState.Completed })
        assertEquals("Terminée", completed.currentStageLabel(stages))
        assertEquals(Recommendation.Tint.Success, completed.stageTint(stages))
        assertTrue(completed.isPipelineComplete(stages))
        assertNull(completed.nextStage(stages))
    }

    @Test fun aLostDealFailsOnItsCurrentStage() {
        val lost = inProgress.copy(status = RecommendationStatus.ArchivedLost)
        assertEquals(StageState.Failed, lost.state(stages[1]))
        assertEquals("Archivée", lost.currentStageLabel(stages))
        assertEquals(Recommendation.Tint.Destructive, lost.stageTint(stages))
    }

    @Test fun amountIsHiddenWhileTheRewardIsPending() {
        assertNull(inProgress.displayedAmount)
        assertEquals(BigDecimal(1000), completed.displayedAmount)
    }

    @Test fun bannerComesFromTheHighestReachedStage() {
        assertNull(inProgress.bannerText(stages))
        assertEquals("Contrat signé. Retrouvez-le dans les documents de la recommandation.", completed.bannerText(stages))
    }

    @Test fun commentPresenceFollowsTheEvents() {
        val rows = inProgress.stepperRows(stages)
        assertTrue(rows[0].comment != null)
        assertTrue(rows.drop(1).all { it.comment == null })
        assertTrue(rows[3].showsReward)
    }

    @Test fun nextStageIsTheFirstUnreachedOne() {
        assertEquals("rdv_programme", inProgress.nextStage(stages)?.key)
        assertEquals("RDV programmé", inProgress.currentStageLabel(stages))
        assertEquals(0.2, inProgress.progress(stages), 1e-9)
    }

    @Test fun stalenessIsAWeekOfSilenceOnAnActiveLead() {
        assertTrue(inProgress.isStale)
        assertFalse(inProgress.copy(status = RecommendationStatus.ArchivedWon).isStale)
        assertEquals("Sans activité depuis 11 jours", RecoStrings.idleFor(11))
        assertEquals("Mise à jour aujourd'hui", RecoStrings.idleFor(1))
    }

    @Test fun invoiceCanBeIssuedOnlyForAnEarnedCommissionWithoutOne() {
        assertFalse(inProgress.canIssueInvoice)
        assertTrue(inProgress.copy(rewardStatus = RewardStatus.Earned).canIssueInvoice)
        assertFalse(completed.copy(rewardStatus = RewardStatus.Earned).canIssueInvoice)
    }

    @Test fun relativeDateWording() {
        val zone = ZoneId.of("Europe/Paris")
        val now = ZonedDateTime.of(2026, 10, 22, 16, 0, 0, 0, zone).toInstant()
        val today = ZonedDateTime.of(2026, 10, 22, 14, 57, 0, 0, zone).toInstant()
        val yesterday = ZonedDateTime.of(2026, 10, 21, 9, 5, 0, 0, zone).toInstant()
        val earlier = ZonedDateTime.of(2026, 9, 17, 14, 57, 0, 0, zone).toInstant()
        val lastYear = ZonedDateTime.of(2025, 9, 17, 14, 57, 0, 0, zone).toInstant()
        assertEquals("Aujourd'hui à 14:57", RecoDates.relativeDate(today, now, zone))
        assertEquals("Hier à 09:05", RecoDates.relativeDate(yesterday, now, zone))
        assertEquals("17/09/2026 à 14:57", RecoDates.relativeDate(earlier, now, zone))
        assertEquals("Aujourd'hui", RecoDates.relativeDay(today, now, zone))
        assertEquals("Hier", RecoDates.relativeDay(yesterday, now, zone))
        assertEquals("17/09", RecoDates.relativeDay(earlier, now, zone))
        assertEquals("17/09/25", RecoDates.relativeDay(lastYear, now, zone))
    }

    @Test fun draftNeedsNamesPhoneAndConsent() {
        val draft = RecommendationDraft(firstName = "Thomas", lastName = "Dubois", phone = "06 75 75 75 75")
        assertFalse(draft.isValid)
        assertTrue(draft.copy(consentConfirmed = true).isValid)
        assertFalse(draft.copy(consentConfirmed = true, phone = "  ").isValid)
        assertFalse(draft.copy(consentConfirmed = true, comment = "x".repeat(2001)).isValid)
        assertNull(draft.copy(comment = "  \n ").trimmedComment)
        assertEquals("Engie", draft.copy(comment = " Engie ").trimmedComment)
    }

    @Test fun duplicateCheckIsAskedOnlyForAFullNumberOrAnAddress() {
        assertFalse(RecommendationDraft(phone = "06 75 75").worthDuplicateCheck)
        assertTrue(RecommendationDraft(phone = "06 75 75 75 75").worthDuplicateCheck)
        assertTrue(RecommendationDraft(email = "a@b.fr").worthDuplicateCheck)
    }

    @Test fun duplicateWarningBlocksOnlyYourOwnLead() {
        val mine = DuplicateCheck(alreadyYours = true)
        val other = DuplicateCheck(heldBySomeoneElse = true)
        assertTrue(mine.blocksSubmission)
        assertEquals(RecoStrings.duplicateAlreadyYours, mine.warning)
        assertFalse(other.blocksSubmission)
        assertEquals(RecoStrings.duplicateHeldByAnother, other.warning)
        assertNull(DuplicateCheck().warning)
        // the server's keys
        val decoded = SupabaseJson.decodeFromString<DuplicateCheck>("""{"already_yours":false,"held_by_someone_else":true}""")
        assertEquals(other, decoded)
    }

    @Test fun commissionAcceptsACommaAndSpaces() {
        assertEquals(BigDecimal("1000.50"), parseCommission("1 000,50"))
        assertEquals(BigDecimal("300"), parseCommission("300"))
        assertEquals(BigDecimal("12.5"), parseCommission("12.5"))
        assertNull(parseCommission("0"))
        assertNull(parseCommission(""))
        assertNull(parseCommission("abc"))
    }

    @Test fun feedRowMapsStageKeysOntoThePipeline() {
        val json = """
            {"id":"r1","filleul_first_name":"Léa","filleul_last_name":"Martin","parrain_name":"Johann Lefeuvre",
             "created_at":"2026-10-20T10:15:30.123456+00:00","current_stage_key":"rdv_programme",
             "reward_status":"earned","status":"active","reward_amount":"450.00","displayed_amount":450,
             "events":[{"stage_key":"a_contacter","stage_label":"À contacter","position":1,"comment":"Bonjour","completed_at":"2026-10-20T11:00:00+00:00"},
                       {"stage_key":"inconnu","completed_at":"2026-10-20T11:00:00+00:00"}],
             "has_contract":false,"invoice_number":null,"invoice_id":null,"days_since_activity":2,
             "has_note":true,"pending_reminders":1,"apporteur_comment":"Joignable après 18 h","new_column":42}
        """.trimIndent()
        val reco = SupabaseJson.decodeFromString<FeedRow>(json).toRecommendation(stages)
        assertEquals(stages[1].id, reco.currentStageId)
        assertEquals(1, reco.events.size)
        assertEquals(stages[0].id, reco.events[0].stageId)
        assertEquals(BigDecimal("450.00"), reco.displayedAmount)
        assertEquals(Instant.parse("2026-10-20T10:15:30.123456Z"), reco.createdAt)
        assertEquals("LM", reco.initials)
    }

    @Test fun actionConfirmationsKeepTheIosCopy() {
        assertEquals("Établir la facture ?", RecoAction.IssueInvoice.confirmTitle)
        assertEquals("Effacer définitivement", RecoAction.EraseFilleul.confirmVerb)
        assertTrue(RecoAction.Delete.isDestructive)
        assertFalse(RecoAction.ArchiveWon.isDestructive)
        assertFalse(RecoAction.Reset.isDestructive)
    }

    @Test fun reminderDefaultsAndOverdue() {
        assertEquals("Relancer Thomas Dubois", Reminder.labelOrDefault("  ", "Thomas Dubois"))
        assertEquals("Appeler", Reminder.labelOrDefault("Appeler", "Thomas Dubois"))
        val now = Instant.parse("2026-10-22T10:00:00Z")
        assertTrue(Reminder("1", "x", now.minusSeconds(1)).isOverdue(now))
        assertFalse(Reminder("1", "x", now.minusSeconds(1), Reminder.Status.Done).isOverdue(now))
        assertEquals(listOf("Demain", "Dans 3 jours", "Dans une semaine"), Reminder.presets.map { it.first })
    }

    @Test fun documentLabelsAndSizes() {
        assertEquals("245 Ko", fileSize(245_000))
        assertEquals("1,2 Mo", fileSize(1_200_000))
        assertEquals("512 octets", fileSize(512))
        val doc = LeadDocument("d", "r", "energy_bill", "r/x.pdf", "Facture.pdf", 245_000, "application/pdf", "u", Instant.EPOCH)
        assertEquals("Facture d'énergie · 245 Ko", doc.subtitle)
        assertTrue(doc.isPdf)
        assertEquals("jpg", DocumentUpload(ByteArray(1), "a.jpg", "image/jpeg").fileExtension)
        assertEquals("heic", DocumentUpload(ByteArray(1), "a.heic", "image/heic").fileExtension)
    }

    @Test fun photosAreShrunkToTheirLongSideNeverEnlarged() {
        assertEquals(2400 to 1800, DocumentSources.targetSize(4032, 3024))
        assertEquals(1800 to 2400, DocumentSources.targetSize(3024, 4032))
        assertEquals(800 to 600, DocumentSources.targetSize(800, 600))
        assertEquals(1, DocumentSources.sampleSize(3000, 2000))
        assertEquals(2, DocumentSources.sampleSize(8000, 6000))
        assertEquals(1, DocumentSources.sampleSize(800, 600))
    }
}
