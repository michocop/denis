package com.trinityenergie.energycourtage.ui.admin

import com.trinityenergie.energycourtage.model.BusinessStatus
import com.trinityenergie.energycourtage.model.MemberOverview
import com.trinityenergie.energycourtage.model.PayableInvoice
import java.math.BigDecimal
import java.time.Instant

/** Where the iPhone app is installed from while it is in beta; the same link
 *  as the invitation email (INSTALL_URL in supabase/functions/auth-email). */
const val IOS_INSTALL_URL = "https://testflight.apple.com/join/cmSnjrEh"

/** Where the Android app is installed from (Play internal testing). Empty
 *  until it is published: the invitation message then leaves Android out. */
const val ANDROID_INSTALL_URL = ""

object InviteText {
    private val emailPattern = Regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")

    fun isValidEmail(email: String): Boolean = emailPattern.matches(email.trim())

    /** What the admin sends by SMS or WhatsApp after an invitation, in case
     *  the email sits in a spam folder (iOS InviteSheet.installMessage). */
    fun installMessage(email: String, androidUrl: String = ANDROID_INSTALL_URL): String = buildString {
        appendLine("Bonjour, je vous invite sur l'application Trinity Énergie.")
        appendLine("1. Installez-la sur votre iPhone : $IOS_INSTALL_URL")
        if (androidUrl.isNotBlank()) appendLine("   ou sur votre téléphone Android : $androidUrl")
        append("2. Ouvrez-la et saisissez votre adresse $email : vous recevrez un code de connexion par e-mail (pensez à regarder dans les indésirables).")
    }
}

val BusinessStatus.label: String
    get() = when (this) { BusinessStatus.Societe -> "Société"; BusinessStatus.Independant -> "Indépendant" }

object MemberRules {
    /** Those waiting on a decision first -- they are blocked on the admin --
     *  then by last activity. */
    fun visible(members: List<MemberOverview>, pendingOnly: Boolean, query: String): List<MemberOverview> =
        members
            .filter { !pendingOnly || it.isPending }
            .filter { query.isEmpty() || it.fullName.contains(query, ignoreCase = true) || it.email.contains(query, ignoreCase = true) }
            .sortedWith(compareByDescending<MemberOverview> { it.isPending }.thenByDescending { it.lastRecommendationAt ?: Instant.MIN })

    fun pendingCount(members: List<MemberOverview>) = members.count { it.isPending }
}

/** The payables run (iOS PayablesViewModel), without the screen. */
object PayableRules {
    /** Grouped by apporteur: a transfer run is organised by beneficiary. */
    fun groups(invoices: List<PayableInvoice>): List<Pair<String, List<PayableInvoice>>> =
        invoices.groupBy { it.apporteurName }
            .map { (name, list) -> name to list.sortedBy { it.issuedOn } }
            .sortedBy { it.first }

    fun selectedTotal(invoices: List<PayableInvoice>, selection: Set<String>): BigDecimal =
        invoices.filter { it.invoiceId in selection }.fold(BigDecimal.ZERO) { acc, i -> acc + i.amountTtc }

    /** Nobody can be paid without bank details, so a selection holding one is
     *  refused here rather than failing at the bank. */
    fun blocked(invoices: List<PayableInvoice>, selection: Set<String>) =
        invoices.filter { it.invoiceId in selection && !it.hasBankDetails }

    fun canPay(invoices: List<PayableInvoice>, selection: Set<String>, working: Boolean) =
        selection.isNotEmpty() && blocked(invoices, selection).isEmpty() && !working

    fun selectAllPayable(invoices: List<PayableInvoice>): Set<String> =
        invoices.filter { it.hasBankDetails }.mapTo(LinkedHashSet()) { it.invoiceId }
}
