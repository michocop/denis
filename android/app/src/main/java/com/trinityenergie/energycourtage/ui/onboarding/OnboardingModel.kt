package com.trinityenergie.energycourtage.ui.onboarding

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.trinityenergie.energycourtage.core.sha256Hex
import com.trinityenergie.energycourtage.data.ContractRepository
import com.trinityenergie.energycourtage.data.Demo
import com.trinityenergie.energycourtage.data.DemoContracts
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.data.LegalRepository
import com.trinityenergie.energycourtage.data.ProfileRepository
import com.trinityenergie.energycourtage.data.SmsRepository
import com.trinityenergie.energycourtage.data.contracts
import com.trinityenergie.energycourtage.model.ApporteurContract
import com.trinityenergie.energycourtage.model.BusinessStatus
import com.trinityenergie.energycourtage.model.LegalDocument
import com.trinityenergie.energycourtage.model.Profile
import com.trinityenergie.energycourtage.model.SigningStep
import com.trinityenergie.energycourtage.model.SmsChallenge
import com.trinityenergie.energycourtage.model.SmsConfirmation
import com.trinityenergie.energycourtage.model.SmsPurpose
import com.trinityenergie.energycourtage.model.Particulier
import com.trinityenergie.energycourtage.model.legalForms
import kotlinx.coroutines.delay

/**
 * True for an apporteur who has not signed the contract yet: the app starts
 * with [OnboardingScreen] for them (RootView, after the CGU and the privacy
 * policy). False for the company's side, which has no contract to sign, and
 * when the profile cannot be read.
 */
suspend fun Dependencies.needsOnboarding(): Boolean {
    if (role.isAdmin) return false
    if (isDemo) return DemoContracts.contract(Demo.me) == null
    val profile = runCatching { profiles.currentProfile() }.getOrNull() ?: return false
    return profile.contractSignedAt == null
}

/**
 * The signed contract of [profileId] as a PDF: the copy the server filed, or
 * null when there is no contract yet or its PDF is still being prepared.
 * Throws on a network or server error, for the caller to say.
 */
suspend fun Dependencies.contractPdf(profileId: String): ByteArray? {
    val repository = contracts()
    val contract = repository.contract(profileId) ?: return null
    return repository.pdf(contract)
}

/**
 * The apporteur's first minutes (iOS OnboardingModel): how they work, who
 * they are for the invoices, then the contract and its annex, signed with one
 * code by SMS.
 */
class OnboardingModel(
    private val profiles: ProfileRepository,
    private val legal: LegalRepository,
    val sms: SmsRepository,
    private val contracts: ContractRepository,
    private val isDemo: Boolean = false,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) {
    enum class Step { Status, Details, Contract, Done }

    var step by mutableStateOf(Step.Status); private set
    var status by mutableStateOf<BusinessStatus?>(null); private set
    var draft by mutableStateOf<Profile?>(null)
    var contract by mutableStateOf<LegalDocument?>(null); private set
    var mandate by mutableStateOf<LegalDocument?>(null); private set
    var hasReadToEnd by mutableStateOf(false)
    var agrees by mutableStateOf(false)
    var signingStep by mutableStateOf<SigningStep?>(null)
    var signed by mutableStateOf<ApporteurContract?>(null); private set
    var errorMessage by mutableStateOf<String?>(null); private set
    var isWorking by mutableStateOf(false); private set
    var isPreparingPdf by mutableStateOf(false); private set
    /** Steps passed, and the signature, each answered with a vibration. */
    var advances by mutableIntStateOf(0); private set
    var signatures by mutableIntStateOf(0); private set

    val firstName get() = draft?.firstName ?: ""

    private fun say(e: Exception) = e.message ?: "Une erreur est survenue. Réessayez."

    suspend fun load() {
        try {
            val profile = profiles.currentProfile()
            if (draft == null) {
                draft = profile
                status = profile.businessStatus
            }
            val documents = legal.documents()
            contract = documents.firstOrNull { it.key == "contrat_apporteur" }
            mandate = documents.firstOrNull { it.key == "mandat_facturation" }
            errorMessage = null
        } catch (e: Exception) {
            errorMessage = say(e)
        }
    }

    // ------------------------------------------------------------- steps

    fun choose(choice: BusinessStatus) {
        val changed = status != choice
        status = choice
        val d = draft ?: return
        if (choice == BusinessStatus.Independant) {
            // a particulier has no SIRET, no company: none is kept
            draft = d.copy(legalForm = Particulier.LEGAL_FORM, siret = null, companyName = null)
        } else if (changed && (d.legalForm ?: "") !in choice.legalForms) {
            // a form that belongs to the other status would read wrong
            draft = d.copy(legalForm = choice.legalForms.first())
        }
    }

    /** The first form preselected, so a company taps nothing. */
    fun preselectLegalForm() {
        val d = draft ?: return
        val forms = status?.legalForms?.takeIf { it.isNotEmpty() } ?: return
        if ((d.legalForm ?: "").isEmpty() || d.legalForm !in forms) draft = d.copy(legalForm = forms.first())
    }

    /** A micro-entrepreneur or sole trader may leave the company name empty. */
    val companyNameOptional: Boolean
        get() = (draft?.legalForm ?: "") in Particulier.soleTraderForms

    fun next() {
        errorMessage = null
        val following = Step.entries.getOrNull(step.ordinal + 1) ?: return
        step = following
        advances += 1
    }

    fun back() {
        errorMessage = null
        if (step == Step.Done) return
        step = Step.entries.getOrNull(step.ordinal - 1) ?: return
    }

    /** What is still missing from the details, said in one line; null when the form can be sent. */
    val detailsProblem: String?
        get() {
            val d = draft
            val s = status
            if (d == null || s == null) return "Choisissez votre statut."
            fun empty(v: String?) = (v ?: "").isBlank()
            if (s == BusinessStatus.Societe) {
                if (empty(d.companyName) && !companyNameOptional) return "Indiquez la raison sociale."
                if ((d.siret ?: "").count(Char::isDigit) != 14) return "Le SIRET compte 14 chiffres."
            }
            if (empty(d.address)) return "Indiquez l'adresse."
            if ((d.postalCode ?: "").count(Char::isDigit) != 5) return "Le code postal compte 5 chiffres."
            if (empty(d.city)) return "Indiquez la ville."
            return null
        }

    suspend fun saveDetails() {
        val d = draft ?: return
        if (detailsProblem != null) return
        isWorking = true
        try {
            val particulier = status == BusinessStatus.Independant
            val cleaned = d.copy(
                siret = if (particulier) null else d.siret?.filter(Char::isDigit),
                legalForm = if (particulier) Particulier.LEGAL_FORM else d.legalForm,
                companyName = if (particulier) null else d.companyName?.trim()?.ifEmpty { null },
                postalCode = d.postalCode?.filter(Char::isDigit),
                businessStatus = status,
            )
            draft = profiles.save(cleaned).copy(businessStatus = status)
            if (contract == null || mandate == null) load()
            next()
        } catch (e: Exception) {
            errorMessage = say(e)
        } finally {
            isWorking = false
        }
    }

    // ----------------------------------------------------------- signing

    /** The digest of the bytes shown: if it differs from the published one,
     *  the text changed on the way, and signing it would sign something else. */
    private fun digest(document: LegalDocument): String? = sha256Hex(document.body).takeIf { it == document.sha256 }

    suspend fun startSigning() {
        errorMessage = null
        isWorking = true
        try {
            val smsStatus = sms.status()
            if (!smsStatus.smsRequired) return sign()
            if (!smsStatus.phoneVerified) {
                signingStep = SigningStep.EnterPhone
                return
            }
            val challenge = sms.requestCode(SmsPurpose.SignContract, null, null)
            if (challenge.required) signingStep = SigningStep.EnterCode(challenge.maskedPhone ?: "votre mobile")
            else sign()
        } catch (e: Exception) {
            errorMessage = say(e)
        } finally {
            isWorking = false
        }
    }

    suspend fun requestCode(phone: String?, resend: Boolean): SmsChallenge =
        sms.requestCode(SmsPurpose.SignContract, null, phone, resend)

    suspend fun confirmCode(code: String): SmsConfirmation = sms.confirm(SmsPurpose.SignContract, code, null)

    suspend fun codeConfirmed() {
        signingStep = null
        sign()
    }

    private suspend fun sign() {
        val s = status
        val c = contract
        val m = mandate
        if (s == null || c == null || m == null) {
            errorMessage = "Le contrat n'est pas disponible. Réessayez dans un instant."
            return
        }
        val contractDigest = digest(c)
        val mandateDigest = digest(m)
        if (contractDigest == null || mandateDigest == null) {
            errorMessage = "Le texte affiché ne correspond pas à celui publié. Rouvrez l'application."
            return
        }
        isWorking = true
        try {
            val result = contracts.sign(s, contractDigest, mandateDigest)
            signed = result
            if (isDemo) recordDemoSignature(result)
            signatures += 1
            step = Step.Done
        } catch (e: Exception) {
            errorMessage = say(e)
        } finally {
            isWorking = false
        }
    }

    /** The demo's profile has no server to stamp it: what the signature sets
     *  for real is recorded on it, so the profile and Accueil show it. */
    private suspend fun recordDemoSignature(contract: ApporteurContract) {
        runCatching {
            val profile = profiles.currentProfile()
            profiles.save(profile.copy(
                contractSignedAt = contract.signedAt,
                billingMandateSignedAt = profile.billingMandateSignedAt ?: contract.signedAt,
                businessStatus = contract.businessStatus,
            ))
        }
    }

    // ------------------------------------------------------------ the PDF

    /** Filed by the server a few seconds after the signature: asked for until
     *  it is there, every 2 s, for up to half a minute. Null when it is not
     *  there yet, with [errorMessage] saying so. */
    suspend fun openPdf(): ByteArray? {
        val contract = signed ?: return null
        if (isPreparingPdf) return null
        isPreparingPdf = true
        errorMessage = null
        try {
            for (attempt in 0 until 15) {
                try {
                    contracts.pdf(contract)?.let { return it }
                } catch (e: Exception) {
                    if (attempt == 14) { errorMessage = say(e); return null }
                }
                pause(2_000)
            }
            errorMessage = "Le PDF est encore en préparation. Il sera disponible dans votre profil."
            return null
        } finally {
            isPreparingPdf = false
        }
    }
}
