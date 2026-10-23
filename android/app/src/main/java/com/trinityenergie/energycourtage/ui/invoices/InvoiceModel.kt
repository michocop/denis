package com.trinityenergie.energycourtage.ui.invoices

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.trinityenergie.energycourtage.data.InvoiceRepository
import com.trinityenergie.energycourtage.data.SmsRepository
import com.trinityenergie.energycourtage.model.InvoiceDocument
import com.trinityenergie.energycourtage.model.SigningStep
import com.trinityenergie.energycourtage.model.SmsChallenge
import com.trinityenergie.energycourtage.model.SmsConfirmation
import com.trinityenergie.energycourtage.model.SmsPurpose
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The invoice screen's state and rules (iOS InvoiceViewModel). [render] draws
 * the document as a PDF on the phone: the preview before both signatures,
 * and the copy shown until the server has filed its own.
 */
class InvoiceModel(
    private val invoiceId: String,
    private val repository: InvoiceRepository,
    val sms: SmsRepository,
    private val render: (InvoiceDocument) -> ByteArray,
) {
    var document by mutableStateOf<InvoiceDocument?>(null); private set
    var errorMessage by mutableStateOf<String?>(null); private set
    var isWorking by mutableStateOf(false); private set
    /** The PDF once fetched or produced, shared as "<number>.pdf". */
    var pdf by mutableStateOf<ByteArray?>(null); private set
    var isPreparingPdf by mutableStateOf(false); private set
    /** Set once a credit note has been issued, so the screen stops offering a second one. */
    var creditNoteIssued by mutableStateOf(false); private set
    /** Signatures that went through, for their vibration -- except one that
     *  follows an SMS code, whose screen has just played its own. */
    var signatures by mutableIntStateOf(0); private set
    /** Set while the apporteur proves their number or types the code. */
    var signingStep by mutableStateOf<SigningStep?>(null)

    private fun fail(e: Exception) { errorMessage = e.message ?: "Une erreur est survenue. Réessayez." }

    suspend fun load() {
        try {
            document = repository.document(invoiceId)
            errorMessage = null
        } catch (e: Exception) {
            fail(e)
        }
    }

    /** Renders what is about to be signed exactly as it will be filed, so the
     *  signer reads the page itself and not only the screen's summary of it. */
    suspend fun previewPdf(): ByteArray? {
        val doc = document ?: return null
        return try {
            withContext(Dispatchers.Default) { render(doc) }
        } catch (e: Exception) {
            fail(e); null
        }
    }

    /** Fetches the retained document, or shows the phone's rendering until it exists. */
    suspend fun preparePdf() {
        val doc = document ?: return
        if (pdf != null || isPreparingPdf) return
        isPreparingPdf = true
        try {
            pdf = withContext(Dispatchers.Default) { repository.pdf(doc, invoiceId, render) }
            errorMessage = null
        } catch (e: Exception) {
            fail(e)
        } finally {
            isPreparingPdf = false
        }
    }

    /** The only lawful correction to a signed invoice: a new document in the
     *  same series carrying the negative amount. */
    suspend fun issueCreditNote(reason: String) {
        isWorking = true
        try {
            repository.createCreditNote(invoiceId, reason)
            creditNoteIssued = true
            errorMessage = null
        } catch (e: Exception) {
            fail(e)
        } finally {
            isWorking = false
        }
    }

    /** "Signer", confirmed. The company signs from an admin's own session; the
     *  apporteur's signature also takes a code sent by SMS to their verified
     *  mobile, once the company has SMS set up. The server enforces this;
     *  here it only decides what comes next. */
    suspend fun startSigning(asCompany: Boolean) {
        errorMessage = null
        if (asCompany) return sign(announced = true)
        isWorking = true
        try {
            val status = sms.status()
            if (!status.smsRequired) {
                isWorking = false
                return sign(announced = true)
            }
            if (!status.phoneVerified) {
                signingStep = SigningStep.EnterPhone
                return
            }
            sendSigningCode()
        } catch (e: Exception) {
            fail(e)
        } finally {
            isWorking = false
        }
    }

    /** Sends the signing code to the proven number. No SMS goes out when the
     *  server needs none -- and the signature then goes ahead. */
    suspend fun sendSigningCode() {
        val challenge = sms.requestCode(SmsPurpose.SignInvoice, invoiceId, null)
        if (challenge.required) {
            signingStep = SigningStep.EnterCode(challenge.maskedPhone ?: "votre mobile")
        } else {
            signingStep = null
            isWorking = false
            sign(announced = true)
        }
    }

    /** From the number step: the code goes to the number typed, and coming
     *  back proves it as well as confirming the signature. */
    suspend fun requestSigningCode(phone: String?, resend: Boolean): SmsChallenge =
        sms.requestCode(SmsPurpose.SignInvoice, invoiceId, phone, resend)

    suspend fun confirmSigningCode(code: String): SmsConfirmation =
        sms.confirm(SmsPurpose.SignInvoice, code, invoiceId)

    /** The code was right: the server holds it for this invoice, and the
     *  signature uses it up. */
    suspend fun codeConfirmed() {
        signingStep = null
        sign(announced = false)
    }

    /** Signs the digest the server issued with the document. */
    private suspend fun sign(announced: Boolean) {
        val digest = document?.documentSha256
        if (digest == null) {
            errorMessage = "Cette facture n'a pas encore de document à signer."
            return
        }
        isWorking = true
        try {
            repository.sign(invoiceId, digest)
            if (announced) signatures += 1
            load()
            // the retained document shows both signatures, so only once the second is in
            if (document?.isFullySigned == true) preparePdf()
        } catch (e: Exception) {
            fail(e)
        } finally {
            isWorking = false
        }
    }
}
