package com.trinityenergie.energycourtage.recommendations

import com.trinityenergie.energycourtage.data.DemoDocumentsRepository
import com.trinityenergie.energycourtage.data.DemoRecommendationsRepository
import com.trinityenergie.energycourtage.data.DemoRemindersRepository
import com.trinityenergie.energycourtage.data.DemoSamples
import com.trinityenergie.energycourtage.data.RecommendationsRepository
import com.trinityenergie.energycourtage.model.DocumentUpload
import com.trinityenergie.energycourtage.model.DuplicateCheck
import com.trinityenergie.energycourtage.model.Profile
import com.trinityenergie.energycourtage.model.Recommendation
import com.trinityenergie.energycourtage.model.RecommendationCursor
import com.trinityenergie.energycourtage.model.RecommendationDraft
import com.trinityenergie.energycourtage.model.RecommendationFilter
import com.trinityenergie.energycourtage.model.RecommendationStatus
import com.trinityenergie.energycourtage.model.Reminder
import com.trinityenergie.energycourtage.model.RewardStatus
import com.trinityenergie.energycourtage.model.UserRole
import com.trinityenergie.energycourtage.ui.recommendations.RecommendationsModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.math.BigDecimal
import java.time.Instant

/** A repository that pages through [all], 20 at a time, by cursor. */
private class PagedRepository(val all: List<Recommendation>) : RecommendationsRepository {
    val searches = mutableListOf<String>()
    var advanced: String? = null
    override suspend fun loadPipeline() = DemoSamples.stages
    override suspend fun loadPage(archived: Boolean, search: String, cursor: RecommendationCursor?): List<Recommendation> {
        searches += search
        val start = cursor?.let { c -> all.indexOfFirst { it.id == c.id } + 1 } ?: 0
        return all.drop(start).take(RecommendationsRepository.PAGE_SIZE)
    }
    override suspend fun advanceStage(recommendationId: String, stageKey: String): Recommendation {
        advanced = stageKey
        return all.first { it.id == recommendationId }.copy(currentStageId = "moved")
    }
    override suspend fun create(draft: RecommendationDraft) = error("unused")
    override suspend fun reassign(recommendationId: String, adminId: String) {}
    override suspend fun setRewardAmount(recommendationId: String, amount: BigDecimal) {}
    override suspend fun archive(recommendationId: String, won: Boolean) {}
    override suspend fun resetPipeline(recommendationId: String) {}
    override suspend fun softDelete(recommendationId: String) {}
    override suspend fun loadAdmins() = emptyList<Profile>()
    override suspend fun appointments() = emptyList<Recommendation>()
    override suspend fun setAppointment(recommendationId: String, at: Instant?) = error("unused")
    override suspend fun checkDuplicate(phone: String, email: String) = DuplicateCheck()
    override suspend fun note(recommendationId: String) = ""
    override suspend fun saveNote(recommendationId: String, body: String) {}
    override suspend fun recommendation(id: String) = all.firstOrNull { it.id == id }
    override suspend fun eraseFilleul(recommendationId: String) {}
    override suspend fun issueInvoice(recommendationId: String) = "inv"
}

private fun reco(i: Int) = DemoSamples.inProgress().copy(id = "r$i", createdAt = Instant.EPOCH.plusSeconds(1000L - i))

@OptIn(ExperimentalCoroutinesApi::class)
class RecommendationsModelTest {
    @Before fun resetDemo() { DemoRecommendationsRepository.reset(); DemoRemindersRepository.reset() }

    @Test fun pagesAreLoadedAsTheLastCardAppears() = runTest {
        val repo = PagedRepository((1..45).map(::reco))
        val model = RecommendationsModel(repo, UserRole.Apporteur, this)
        model.load()
        assertEquals(RecommendationsModel.LoadState.Loaded, model.state)
        assertEquals(20, model.recommendations.size)
        assertTrue(model.hasMorePages)
        // not the last card: nothing
        model.loadNextPageIfNeeded(model.recommendations[5])
        assertEquals(20, model.recommendations.size)
        model.loadNextPageIfNeeded(model.recommendations.last())
        assertEquals(40, model.recommendations.size)
        model.loadNextPageIfNeeded(model.recommendations.last())
        assertEquals(45, model.recommendations.size)
        assertFalse(model.hasMorePages)
        assertEquals(45, model.recommendations.map { it.id }.toSet().size)
    }

    @Test fun searchIsDebouncedAndTrimmed() = runTest {
        val repo = PagedRepository(listOf(reco(1)))
        val model = RecommendationsModel(repo, UserRole.Apporteur, this)
        model.updateQuery("D"); advanceTimeBy(100)
        model.updateQuery("Du"); advanceTimeBy(100)
        model.updateQuery("Dubois "); advanceTimeBy(351); runCurrent()
        assertEquals(listOf("Dubois"), repo.searches)
    }

    @Test fun apporteurCannotAdvanceAStage() = runTest {
        val repo = PagedRepository(listOf(reco(1)))
        val model = RecommendationsModel(repo, UserRole.Apporteur, this)
        model.load()
        model.validateNextStage(model.recommendations[0])
        assertNull(repo.advanced)
        assertEquals(0, model.stageAdvances)
    }

    @Test fun adminAdvancesToTheNextUnreachedStage() = runTest {
        val repo = PagedRepository(listOf(reco(1)))
        val model = RecommendationsModel(repo, UserRole.Admin, this)
        model.load()
        model.validateNextStage(model.recommendations[0])
        assertEquals("rdv_programme", repo.advanced)
        assertEquals("moved", model.recommendations[0].currentStageId)
        assertEquals(1, model.stageAdvances)
    }

    @Test fun anEmptyFilterIsSaidSo() = runTest {
        val model = RecommendationsModel(DemoRecommendationsRepository, UserRole.Apporteur, this)
        model.load()
        assertEquals(2, model.recommendations.size)
        model.selectFilter(RecommendationFilter.Archived); runCurrent(); advanceTimeBy(500); runCurrent()
        assertTrue(model.isEmpty)
    }

    @Test fun theDemoKeepsWhatIsDoneToIt() = runTest {
        val demo = DemoRecommendationsRepository
        val id = DemoSamples.inProgress().id
        for (key in listOf("rdv_programme", "proposition_envoyee", "devis_signe")) demo.advanceStage(id, key)
        var r = demo.recommendation(id)!!
        assertEquals(RewardStatus.Earned, r.rewardStatus)
        assertTrue(r.canIssueInvoice)
        assertEquals(DemoSamples.invoiceId, demo.issueInvoice(id))
        r = demo.recommendation(id)!!
        assertEquals(RewardStatus.Invoiced, r.rewardStatus)
        assertEquals("FA-2026-0002", r.invoiceNumber)

        demo.archive(id, won = true)
        assertTrue(demo.loadPage(archived = false, search = "", cursor = null).none { it.id == id })
        assertEquals(RecommendationStatus.ArchivedWon, demo.loadPage(true, "", null).single().status)

        val made = demo.create(RecommendationDraft(firstName = "Léa", lastName = "Martin", phone = "06 11 22 33 44", consentConfirmed = true))
        assertEquals(made.id, demo.loadPage(false, "martin", null).single().id)
        assertTrue(demo.checkDuplicate("+33 6 11 22 33 44", "").alreadyYours)
        demo.saveNote(made.id, "Rappeler")
        assertEquals("Rappeler", demo.note(made.id))
        assertTrue(demo.recommendation(made.id)!!.hasNote)
    }

    @Test fun demoRemindersAndDocumentsPersist() = runTest {
        val reminders = DemoRemindersRepository
        assertEquals(2, reminders.reminders("x").size)
        val made = reminders.schedule("x", "Appeler", Instant.now().plusSeconds(3600))
        reminders.complete(made.id)
        assertEquals(Reminder.Status.Done, reminders.reminders("x").first { it.id == made.id }.status)

        val doc = DemoDocumentsRepository.add(DocumentUpload(byteArrayOf(9), "a.pdf", "application/pdf"), "x")
        assertEquals(listOf(doc.id), DemoDocumentsRepository.documents("x").map { it.id })
        assertEquals(1, DemoDocumentsRepository.data(doc).size)
        DemoDocumentsRepository.remove(doc)
        assertTrue(DemoDocumentsRepository.documents("x").isEmpty())
    }

}
