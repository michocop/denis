package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.model.ChatMessage
import com.trinityenergie.energycourtage.model.ChatThread
import com.trinityenergie.energycourtage.model.CommissionLine
import com.trinityenergie.energycourtage.model.MemberOverview
import com.trinityenergie.energycourtage.model.PayableInvoice
import com.trinityenergie.energycourtage.model.ThreadKind
import com.trinityenergie.energycourtage.ui.admin.IOS_INSTALL_URL
import com.trinityenergie.energycourtage.ui.admin.InviteText
import com.trinityenergie.energycourtage.ui.admin.MemberRules
import com.trinityenergie.energycourtage.ui.admin.PayableRules
import com.trinityenergie.energycourtage.ui.chat.ChatFilter
import com.trinityenergie.energycourtage.ui.chat.ChatRules
import com.trinityenergie.energycourtage.ui.chat.ChatSegment
import com.trinityenergie.energycourtage.ui.money.CommissionRules
import com.trinityenergie.energycourtage.ui.profile.BillingRules
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigDecimal
import java.time.Instant

class ChatAdminRulesTest {
    private val now = Instant.parse("2026-10-20T10:00:00Z")

    private fun thread(id: String, kind: ThreadKind = ThreadKind.Direct, minutesAgo: Long = 0, pinned: Boolean = false,
                       archived: Boolean = false, unread: Int = 0, name: String = id) =
        ChatThread(id, kind, counterpartName = name, lastMessageAt = now.minusSeconds(minutesAgo * 60),
            unreadCount = unread, pinned = pinned, archived = archived)

    @Test fun pinnedFirstThenMostRecent() {
        val list = listOf(thread("old", minutesAgo = 100), thread("new", minutesAgo = 1), thread("pin", minutesAgo = 500, pinned = true))
        assertEquals(listOf("pin", "new", "old"), ChatRules.visibleThreads(list, ChatSegment.Discussions, ChatFilter.All, "").map { it.id })
    }

    @Test fun filtersAndSegments() {
        val list = listOf(
            thread("a", unread = 2), thread("b", archived = true, unread = 1), thread("g", ThreadKind.Group),
            thread("t", ThreadKind.Ticket), thread("p", pinned = true, archived = true),
        )
        fun ids(s: ChatSegment, f: ChatFilter, q: String = "") = ChatRules.visibleThreads(list, s, f, q).map { it.id }.toSet()
        assertEquals(setOf("a", "g"), ids(ChatSegment.Discussions, ChatFilter.All))
        assertEquals(setOf("a"), ids(ChatSegment.Discussions, ChatFilter.Unread))
        assertEquals(setOf("g"), ids(ChatSegment.Discussions, ChatFilter.Groups))
        assertEquals(setOf("p"), ids(ChatSegment.Discussions, ChatFilter.Pinned))
        assertEquals(setOf("b", "p"), ids(ChatSegment.Discussions, ChatFilter.Archived))
        assertEquals(setOf("t"), ids(ChatSegment.Tickets, ChatFilter.All))
        // "Groupes" left selected while on Tickets falls back to Toutes
        assertEquals(setOf("t"), ids(ChatSegment.Tickets, ChatFilter.Groups))
        assertFalse(ChatFilter.Groups in ChatRules.availableFilters(ChatSegment.Tickets))
        assertEquals(setOf("g"), ids(ChatSegment.Discussions, ChatFilter.All, "G"))
    }

    @Test fun pollAppendsOnlyWhatIsNew() {
        fun m(id: String) = ChatMessage(id, "t", "s", body = id, createdAt = now)
        val shown = listOf(m("1"), m("2"))
        assertEquals(emptyList<ChatMessage>(), ChatRules.arrived(shown, listOf(m("1"), m("2"))))
        assertEquals(listOf("3"), ChatRules.arrived(shown, listOf(m("1"), m("2"), m("3"))).map { it.id })
    }

    @Test fun membersPendingFirstAndSearchable() {
        val members = listOf(
            MemberOverview("1", "Paul Riviere", "paul@x.fr", status = "active", lastRecommendationAt = now),
            MemberOverview("2", "Marie Durand", "marie@x.fr", status = "pending"),
            MemberOverview("3", "Johann Lefeuvre", "johann@x.fr", status = "active", lastRecommendationAt = now.plusSeconds(60)),
        )
        assertEquals(listOf("2", "3", "1"), MemberRules.visible(members, false, "").map { it.id })
        assertEquals(listOf("2"), MemberRules.visible(members, true, "").map { it.id })
        assertEquals(listOf("3"), MemberRules.visible(members, false, "JOHANN@").map { it.id })
        assertEquals(1, MemberRules.pendingCount(members))
    }

    @Test fun payablesRefuseAnUnpayableSelection() {
        val invoices = listOf(
            PayableInvoice("a", "FA-2", now, BigDecimal(300), "j", "Johann", true, "r", "Thomas"),
            PayableInvoice("b", "FA-1", now.minusSeconds(10), BigDecimal(750), "j", "Johann", true, "r", "Claire"),
            PayableInvoice("c", "FA-3", now, BigDecimal(500), "p", "Paul", false, "r", "Luc"),
        )
        assertEquals(setOf("a", "b"), PayableRules.selectAllPayable(invoices))
        assertEquals(0, BigDecimal(1050).compareTo(PayableRules.selectedTotal(invoices, setOf("a", "b"))))
        assertTrue(PayableRules.canPay(invoices, setOf("a"), working = false))
        assertFalse(PayableRules.canPay(invoices, setOf("a", "c"), working = false))
        assertFalse(PayableRules.canPay(invoices, emptySet(), working = false))
        assertFalse(PayableRules.canPay(invoices, setOf("a"), working = true))
        val groups = PayableRules.groups(invoices)
        assertEquals(listOf("Johann", "Paul"), groups.map { it.first })
        assertEquals(listOf("FA-1", "FA-2"), groups.first().second.map { it.number })
    }

    @Test fun statementTotalsAndExport() {
        val lines = listOf(
            CommissionLine("1", 2026, "Thomas Dubois", BigDecimal(1000), "paid", "FA-2026-0001", now),
            CommissionLine("2", 2026, "Claire Petit", BigDecimal("300.50"), "invoiced", "FA-2026-0002", now.plusSeconds(60)),
            CommissionLine("3", 2026, "Luc Martin", BigDecimal(750), "earned"),
            CommissionLine("4", 2025, "Ancien", BigDecimal(100), "paid"),
        )
        val y = CommissionRules.forYear(lines, 2026)
        assertEquals(listOf(2026, 2025), CommissionRules.years(lines))
        assertEquals(0, BigDecimal("2050.50").compareTo(CommissionRules.earned(y)))
        assertEquals(0, BigDecimal(1000).compareTo(CommissionRules.paid(y)))
        assertEquals(0, BigDecimal("1050.50").compareTo(CommissionRules.outstanding(y)))
        val text = CommissionRules.exportText("Johann Lefeuvre", 2026, lines)
        assertEquals(
            listOf(
                "Relevé d'apport d'affaires — Johann Lefeuvre — 2026", "",
                "— | Luc Martin | 750 EUR | Acquise",
                "FA-2026-0001 | Thomas Dubois | 1000 EUR | Réglée",
                "FA-2026-0002 | Claire Petit | 300.5 EUR | Facturée",
                "", "Total acquis : 2050.5 EUR", "Total réglé  : 1000 EUR", "",
                "Sommes à déclarer au titre des bénéfices non commerciaux (BNC), déclaration de revenus CERFA 2042 C.",
            ).joinToString("\n"),
            text,
        )
    }

    @Test fun installMessageNamesAndroidOnlyWhenThereIsALink() {
        val ios = InviteText.installMessage("nina@example.test", androidUrl = "")
        assertTrue(ios.contains(IOS_INSTALL_URL))
        assertFalse(ios.contains("Android"))
        assertTrue(ios.contains("saisissez votre adresse nina@example.test"))
        val both = InviteText.installMessage("nina@example.test", androidUrl = "https://play.google.com/apps/testing/x")
        assertTrue(both.contains("Android : https://play.google.com/apps/testing/x"))
        assertTrue(InviteText.isValidEmail(" a@b.fr "))
        assertFalse(InviteText.isValidEmail("a@b"))
    }

    @Test fun billingValidation() {
        assertNull(BillingRules.validationProblem("123 456 789 00012", "59000"))
        assertEquals("Le SIRET compte 14 chiffres.", BillingRules.validationProblem("1234", null))
        assertEquals("Le code postal compte 5 chiffres.", BillingRules.validationProblem(null, "590"))
        assertNull(BillingRules.validationProblem("", ""))
    }

    @Test fun demoChatKeepsWhatIsDone() = runTest {
        DemoChatStore.reset()
        val johann = DemoChatRepository(Demo.me)
        johann.setFlags(DemoChatStore.supportThread, pinned = true, archived = null)
        johann.send("Merci", DemoChatStore.supportThread)
        val ticket = johann.openTicket("Virement", "Pas reçu")
        val threads = johann.loadThreads()
        assertTrue(threads.first { it.id == DemoChatStore.supportThread }.pinned)
        assertEquals("Merci", threads.first { it.id == DemoChatStore.supportThread }.lastMessage)
        assertEquals(ThreadKind.Ticket, threads.first { it.id == ticket }.kind)
        // the admin sees the same conversation named after the apporteur
        val admin = DemoChatRepository(Demo.them)
        assertEquals("Johann Lefeuvre", admin.loadThreads().first { it.id == DemoChatStore.supportThread }.counterpartName)
        assertEquals(DemoChatStore.supportThread, admin.startDirectThread(Demo.me))
        DemoChatStore.reset()
    }

    @Test fun demoPayoutClearsThePaidInvoices() = runTest {
        DemoAdminStore.reset()
        DemoAdminRepository.approve(DemoAdminStore.marie)
        DemoAdminRepository.payBatch(listOf("ffffffff-0000-0000-0000-000000000004"), null)
        assertTrue(DemoAdminRepository.members().first { it.id == DemoAdminStore.marie }.isActive)
        assertEquals(2, DemoAdminRepository.payableInvoices().size)
        DemoAdminRepository.setBankDetailsOnFile(DemoAdminStore.paul, true, null)
        assertTrue(DemoAdminRepository.payableInvoices().all { it.hasBankDetails })
        DemoAdminStore.reset()
    }
}
