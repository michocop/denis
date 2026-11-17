package com.trinityenergie.energycourtage.signing

import com.trinityenergie.energycourtage.model.CommissionCap
import com.trinityenergie.energycourtage.core.sha256Hex
import com.trinityenergie.energycourtage.data.ContractRepository
import com.trinityenergie.energycourtage.data.DemoInvoices
import com.trinityenergie.energycourtage.data.InvoiceRepository
import com.trinityenergie.energycourtage.data.LegalRepository
import com.trinityenergie.energycourtage.data.ProfileRepository
import com.trinityenergie.energycourtage.data.SmsRepository
import com.trinityenergie.energycourtage.model.ApporteurContract
import com.trinityenergie.energycourtage.model.BusinessStatus
import com.trinityenergie.energycourtage.model.DashboardStats
import com.trinityenergie.energycourtage.model.InvoiceDocument
import com.trinityenergie.energycourtage.model.LegalDocument
import com.trinityenergie.energycourtage.model.Profile
import com.trinityenergie.energycourtage.model.SigningStep
import com.trinityenergie.energycourtage.model.SmsChallenge
import com.trinityenergie.energycourtage.model.SmsConfirmation
import com.trinityenergie.energycourtage.model.SmsPurpose
import com.trinityenergie.energycourtage.model.SmsStatus
import com.trinityenergie.energycourtage.ui.invoices.InvoiceModel
import com.trinityenergie.energycourtage.ui.legal.LegalModel
import com.trinityenergie.energycourtage.ui.onboarding.OnboardingModel
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

private class FakeSms(var status: SmsStatus, var challenge: SmsChallenge = SmsChallenge(required = true, maskedPhone = "+33 6 •• •• •• 78")) : SmsRepository {
    val requests = mutableListOf<Triple<SmsPurpose, String?, String?>>()
    override suspend fun status() = status
    override suspend fun requestCode(purpose: SmsPurpose, invoiceId: String?, phone: String?, resend: Boolean): SmsChallenge {
        requests += Triple(purpose, invoiceId, phone); return challenge
    }
    override suspend fun confirm(purpose: SmsPurpose, code: String, invoiceId: String?) = SmsConfirmation(ok = code == "123456")
}

/** The demo invoice, behind a counter of what was asked. */
private class CountingInvoices : InvoiceRepository by DemoInvoices {
    val signed = mutableListOf<String>()
    var pdfs = 0
    override suspend fun sign(invoiceId: String, documentSha256: String) { signed += documentSha256; DemoInvoices.sign(invoiceId, documentSha256) }
    override suspend fun pdf(document: InvoiceDocument, invoiceId: String, renderLocally: (InvoiceDocument) -> ByteArray): ByteArray {
        pdfs += 1; return renderLocally(document)
    }
}

class InvoiceSigningTest {
    private fun model(sms: SmsRepository, repo: InvoiceRepository) = InvoiceModel("inv", repo, sms) { "pdf".toByteArray() }

    @Test fun theCompanySignsDirectlyAndThePdfFollows() = runTest {
        DemoInvoices.reset()
        val sms = FakeSms(SmsStatus(smsRequired = true, phoneVerified = true))
        val repo = CountingInvoices()
        val m = model(sms, repo)
        m.load()
        m.startSigning(asCompany = true)
        assertEquals(listOf(DemoInvoices.SAMPLE_DIGEST), repo.signed)
        assertTrue(sms.requests.isEmpty())
        assertTrue(m.document!!.isFullySigned)
        assertEquals(1, repo.pdfs)
        assertNotNull(m.pdf)
        assertEquals(1, m.signatures)
        DemoInvoices.reset()
    }

    @Test fun withoutSmsTheApporteurSignsDirectly() = runTest {
        val repo = CountingInvoices()
        val m = model(FakeSms(SmsStatus(smsRequired = false, phoneVerified = false)), repo)
        m.load()
        m.startSigning(asCompany = false)
        assertEquals(1, repo.signed.size)
        assertNull(m.signingStep)
        DemoInvoices.reset()
    }

    @Test fun anUnprovenNumberAsksForTheNumberFirst() = runTest {
        val repo = CountingInvoices()
        val sms = FakeSms(SmsStatus(smsRequired = true, phoneVerified = false))
        val m = model(sms, repo)
        m.load()
        m.startSigning(asCompany = false)
        assertEquals(SigningStep.EnterPhone, m.signingStep)
        assertTrue(repo.signed.isEmpty())
        // the number step sends the code to the number typed, bound to this invoice
        m.requestSigningCode("+33612345678", resend = false)
        assertEquals(Triple(SmsPurpose.SignInvoice, "inv", "+33612345678"), sms.requests.single())
        assertTrue(m.confirmSigningCode("123456").ok)
        m.codeConfirmed()
        assertNull(m.signingStep)
        assertEquals(1, repo.signed.size)
        assertEquals(0, m.signatures)   // the code screen played its own success
        DemoInvoices.reset()
    }

    @Test fun aProvenNumberGetsTheCode() = runTest {
        val repo = CountingInvoices()
        val sms = FakeSms(SmsStatus(smsRequired = true, phoneVerified = true))
        val m = model(sms, repo)
        m.load()
        m.startSigning(asCompany = false)
        assertEquals(SigningStep.EnterCode("+33 6 •• •• •• 78"), m.signingStep)
        assertEquals(Triple(SmsPurpose.SignInvoice, "inv", null), sms.requests.single())
        assertTrue(repo.signed.isEmpty())
    }

    @Test fun aSigningWindowSkipsTheCode() = runTest {
        val repo = CountingInvoices()
        val sms = FakeSms(SmsStatus(smsRequired = true, phoneVerified = true), SmsChallenge(required = false, session = true))
        val m = model(sms, repo)
        m.load()
        m.startSigning(asCompany = false)
        assertNull(m.signingStep)
        assertEquals(1, repo.signed.size)
        DemoInvoices.reset()
    }

    @Test fun noDigestNoSignature() = runTest {
        val repo = object : InvoiceRepository by DemoInvoices {
            override suspend fun document(invoiceId: String) = DemoInvoices.document(invoiceId).copy(documentSha256 = null)
            override suspend fun sign(invoiceId: String, documentSha256: String) = error("must not sign")
        }
        val m = model(FakeSms(SmsStatus(false, false)), repo)
        m.load()
        m.startSigning(asCompany = true)
        assertEquals("Cette facture n'a pas encore de document à signer.", m.errorMessage)
    }
}

private class FakeProfiles(var profile: Profile) : ProfileRepository {
    var saves = 0
    override suspend fun currentProfile() = profile
    override suspend fun save(profile: Profile): Profile { saves += 1; this.profile = profile; return profile }
    override suspend fun dashboardStats() = DashboardStats()
    override suspend fun deleteAccount() {}
    override suspend fun exportMyData() = "{}"
    override suspend fun commissionCap() = CommissionCap()
}

private class FakeLegal(val docs: MutableList<LegalDocument>) : LegalRepository {
    val accepted = mutableListOf<Pair<String, String>>()
    override suspend fun documents() = docs.toList()
    override suspend fun accept(key: String, sha256: String) {
        accepted += key to sha256
        docs.replaceAll { if (it.key == key) it.copy(accepted = true) else it }
    }
}

private class FakeContracts(var pdfAfter: Int = 0) : ContractRepository {
    var signedWith: Triple<BusinessStatus, String, String>? = null
    var pdfCalls = 0
    override suspend fun contract(profileId: String): ApporteurContract? = null
    override suspend fun sign(status: BusinessStatus, contractSha256: String, mandateSha256: String): ApporteurContract {
        signedWith = Triple(status, contractSha256, mandateSha256)
        return ApporteurContract("abcdef12-0000", "me", Instant.now(), status, "1", "Johann Lefeuvre", otpVerified = true)
    }
    override suspend fun pdf(contract: ApporteurContract): ByteArray? {
        pdfCalls += 1
        return if (pdfCalls > pdfAfter) "%PDF".toByteArray() else null
    }
}

private fun doc(key: String, body: String, sha: String = sha256Hex(body)) = LegalDocument(key, "1", key, body, sha)

class OnboardingFlowTest {
    private val me = Profile(id = "me", firstName = "Johann", lastName = "Lefeuvre", email = "j@x.fr", phone = "0612345678")

    private fun model(legal: FakeLegal = FakeLegal(mutableListOf(doc("contrat_apporteur", "Contrat"), doc("mandat_facturation", "Mandat"))),
                      sms: SmsRepository = FakeSms(SmsStatus(smsRequired = false, phoneVerified = false)),
                      contracts: FakeContracts = FakeContracts(),
                      profiles: FakeProfiles = FakeProfiles(me)) =
        OnboardingModel(profiles, legal, sms, contracts, pause = {})

    @Test fun detailsSayWhatIsMissing() = runTest {
        val m = model()
        m.load()
        assertEquals("Choisissez votre statut.", m.detailsProblem)
        m.choose(BusinessStatus.Societe)
        assertEquals("SASU", m.draft!!.legalForm)
        assertEquals("Indiquez la raison sociale.", m.detailsProblem)
        m.draft = m.draft!!.copy(companyName = "Lefeuvre Conseil", siret = "123 456 789")
        assertEquals("Le SIRET compte 14 chiffres.", m.detailsProblem)
        m.draft = m.draft!!.copy(siret = "123 456 789 00011")
        assertEquals("Indiquez l'adresse.", m.detailsProblem)
        m.draft = m.draft!!.copy(address = "12 rue des Lilas", postalCode = "590")
        assertEquals("Le code postal compte 5 chiffres.", m.detailsProblem)
        m.draft = m.draft!!.copy(postalCode = "59000")
        assertEquals("Indiquez la ville.", m.detailsProblem)
        m.draft = m.draft!!.copy(city = "Lille")
        assertNull(m.detailsProblem)
    }

    @Test fun aMicroEntrepreneurNeedsNoCompanyNameButASiret() = runTest {
        val m = model()
        m.load()
        m.choose(BusinessStatus.Societe)
        m.draft = m.draft!!.copy(legalForm = "Micro-entrepreneur", companyName = null,
            address = "12 rue des Lilas", postalCode = "59000", city = "Lille")
        assertTrue(m.companyNameOptional)
        assertEquals("Le SIRET compte 14 chiffres.", m.detailsProblem)
        m.draft = m.draft!!.copy(siret = "123 456 789 00011")
        assertNull(m.detailsProblem)
    }

    @Test fun aParticulierNeedsNoSiretAndKeepsNone() = runTest {
        val m = model()
        m.load()
        m.choose(BusinessStatus.Societe)
        m.draft = m.draft!!.copy(companyName = "Lefeuvre Conseil", siret = "12345678900011")
        m.choose(BusinessStatus.Independant)
        assertEquals("Particulier", m.draft!!.legalForm)
        assertNull(m.draft!!.companyName)
        assertNull(m.draft!!.siret)
        m.draft = m.draft!!.copy(address = "12 rue des Lilas", postalCode = "59000", city = "Lille")
        assertNull(m.detailsProblem)
    }

    @Test fun savingTheDetailsCleansThemAndMovesOn() = runTest {
        val profiles = FakeProfiles(me)
        val m = model(profiles = profiles)
        m.load()
        m.choose(BusinessStatus.Societe)
        m.next()
        m.draft = m.draft!!.copy(companyName = " Lefeuvre Conseil ", siret = "123 456 789 00011",
            address = "12 rue", postalCode = "59000", city = "Lille")
        m.saveDetails()
        assertEquals(OnboardingModel.Step.Contract, m.step)
        assertEquals("12345678900011", profiles.profile.siret)
        assertEquals("Lefeuvre Conseil", profiles.profile.companyName)
        assertEquals(BusinessStatus.Societe, profiles.profile.businessStatus)
    }

    @Test fun aParticulierIsSavedWithoutSiret() = runTest {
        val profiles = FakeProfiles(me.copy(siret = "12345678900011", companyName = "Ancienne SARL"))
        val m = model(profiles = profiles)
        m.load()
        m.choose(BusinessStatus.Independant)
        m.next()
        m.draft = m.draft!!.copy(address = "12 rue", postalCode = "59000", city = "Lille")
        m.saveDetails()
        assertEquals(OnboardingModel.Step.Contract, m.step)
        assertNull(profiles.profile.siret)
        assertNull(profiles.profile.companyName)
        assertEquals("Particulier", profiles.profile.legalForm)
        assertEquals(BusinessStatus.Independant, profiles.profile.businessStatus)
    }

    @Test fun theCeilingAlertsFrom1800AndIsReachedAt2400() {
        assertNull(CommissionCap(particulier = false, year = 2026, total = 5000.0).alert)
        assertNull(CommissionCap(particulier = true, year = 2026, total = 1799.99).alert)
        assertEquals(CommissionCap.Alert.Approaching, CommissionCap(particulier = true, year = 2026, total = 1800.0).alert)
        assertEquals(CommissionCap.Alert.Reached, CommissionCap(particulier = true, year = 2026, total = 2400.0).alert)
    }

    @Test fun signsWithTheDigestsOfTheTextsShown() = runTest {
        val contracts = FakeContracts()
        val m = model(contracts = contracts)
        m.load()
        m.choose(BusinessStatus.Independant)
        m.startSigning()
        assertEquals(Triple(BusinessStatus.Independant, sha256Hex("Contrat"), sha256Hex("Mandat")), contracts.signedWith)
        assertEquals(OnboardingModel.Step.Done, m.step)
        assertEquals(1, m.signatures)
    }

    @Test fun refusesATextThatDiffersFromThePublishedOne() = runTest {
        val contracts = FakeContracts()
        val legal = FakeLegal(mutableListOf(doc("contrat_apporteur", "Contrat", sha = "0000"), doc("mandat_facturation", "Mandat")))
        val m = model(legal = legal, contracts = contracts)
        m.load()
        m.choose(BusinessStatus.Societe)
        m.startSigning()
        assertNull(contracts.signedWith)
        assertEquals("Le texte affiché ne correspond pas à celui publié. Rouvrez l'application.", m.errorMessage)
    }

    @Test fun smsFirstWhenRequired() = runTest {
        val sms = FakeSms(SmsStatus(smsRequired = true, phoneVerified = true))
        val contracts = FakeContracts()
        val m = model(sms = sms, contracts = contracts)
        m.load()
        m.choose(BusinessStatus.Societe)
        m.startSigning()
        assertEquals(SigningStep.EnterCode("+33 6 •• •• •• 78"), m.signingStep)
        assertEquals(SmsPurpose.SignContract, sms.requests.single().first)
        assertNull(contracts.signedWith)
        m.codeConfirmed()
        assertNotNull(contracts.signedWith)
    }

    @Test fun thePdfIsAskedForUntilItIsFiled() = runTest {
        val contracts = FakeContracts(pdfAfter = 3)
        val m = model(contracts = contracts)
        m.load(); m.choose(BusinessStatus.Societe); m.startSigning()
        assertNotNull(m.openPdf())
        assertEquals(4, contracts.pdfCalls)
    }

    @Test fun thePdfGivesUpAfterFifteenTries() = runTest {
        val contracts = FakeContracts(pdfAfter = 100)
        val m = model(contracts = contracts)
        m.load(); m.choose(BusinessStatus.Societe); m.startSigning()
        assertNull(m.openPdf())
        assertEquals(15, contracts.pdfCalls)
        assertEquals("Le PDF est encore en préparation. Il sera disponible dans votre profil.", m.errorMessage)
        assertFalse(m.isPreparingPdf)
    }
}

class LegalAcceptanceTest {
    @Test fun acceptSendsTheLocalDigest() = runTest {
        val legal = FakeLegal(mutableListOf(doc("cgu", "Conditions générales")))
        val m = LegalModel(legal)
        m.load()
        assertTrue(m.accept(m.documents.single()))
        assertEquals(listOf("cgu" to sha256Hex("Conditions générales")), legal.accepted)
        assertEquals(1, m.acceptances)
    }

    @Test fun refusesAnAlteredText() = runTest {
        val legal = FakeLegal(mutableListOf(doc("cgu", "Conditions générales", sha = "ffff")))
        val m = LegalModel(legal)
        m.load()
        assertFalse(m.accept(m.documents.single()))
        assertTrue(legal.accepted.isEmpty())
        assertTrue(m.errorMessage!!.startsWith("Le document affiché ne correspond pas à celui publié."))
    }
}
