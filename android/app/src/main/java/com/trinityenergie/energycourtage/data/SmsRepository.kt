package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.model.MobileNumber
import com.trinityenergie.energycourtage.model.SmsChallenge
import com.trinityenergie.energycourtage.model.SmsConfirmation
import com.trinityenergie.energycourtage.model.SmsException
import com.trinityenergie.energycourtage.model.SmsPurpose
import com.trinityenergie.energycourtage.model.SmsStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant

interface SmsRepository {
    suspend fun status(): SmsStatus

    /** Sends a code -- or not: the server reuses one still on its way unless
     *  [resend] asks for a new one, and skips it inside a signing window.
     *  For a signature, [phone] sends the code to a number not yet proven;
     *  the code then proves it and confirms the signature with one SMS. */
    suspend fun requestCode(purpose: SmsPurpose, invoiceId: String?, phone: String?, resend: Boolean = false): SmsChallenge

    suspend fun confirm(purpose: SmsPurpose, code: String, invoiceId: String?): SmsConfirmation
}

/** Codes by SMS (migration 20261005000002_sms.sql). The database writes the
 *  code, keeps only its hash and hands the text to the send-sms function;
 *  the app only ever sees a masked number. */
class SupabaseSmsRepository(private val client: SupabaseClient) : SmsRepository {
    override suspend fun status(): SmsStatus = client.decode(client.rpc("my_sms_status"))

    override suspend fun requestCode(purpose: SmsPurpose, invoiceId: String?, phone: String?, resend: Boolean): SmsChallenge =
        client.decode(client.rpc("request_sms_code", buildJsonObject {
            put("p_purpose", purpose.raw)
            put("p_resend", resend)
            if (invoiceId != null) put("p_invoice_id", invoiceId)
            if (phone != null) put("p_phone", phone)
        }))

    override suspend fun confirm(purpose: SmsPurpose, code: String, invoiceId: String?): SmsConfirmation =
        client.decode(client.rpc("confirm_sms_code", buildJsonObject {
            put("p_purpose", purpose.raw)
            put("p_code", MobileNumber.code(code))
            if (invoiceId != null) put("p_invoice_id", invoiceId)
        }))
}

/**
 * SMS for the demo (iOS PreviewSmsRepository, as the demo builds it:
 * `required: true`). The code is always [DEMO_CODE], and is shown on the code
 * screen, since no SMS is ever sent. A singleton, so a number proven in one
 * screen stays proven in the next.
 */
object DemoSms : SmsRepository {
    const val DEMO_CODE = "123456"
    const val HINT = "Démo : le code est $DEMO_CODE."

    private val lock = Mutex()
    private var required = true
    private var verifiedPhone: String? = null
    private var attempts = 0
    private var pending: String? = null
    private var pendingPurpose: SmsPurpose? = null
    private var signingWindowEnds: Instant? = null
    /** SMS "sent", for tests. */
    var sent = 0
        private set

    /** For tests, which share this object. */
    suspend fun reset(required: Boolean = true, verifiedPhone: String? = null) = lock.withLock {
        this.required = required; this.verifiedPhone = verifiedPhone
        attempts = 0; pending = null; pendingPurpose = null; signingWindowEnds = null; sent = 0
    }

    fun mask(e164: String): String =
        if (e164.startsWith("+33") && e164.length == 12) "+33 ${e164.drop(3).take(1)} •• •• •• ${e164.takeLast(2)}"
        else "${e164.take(3)} •••• ${e164.takeLast(2)}"

    override suspend fun status(): SmsStatus = lock.withLock {
        SmsStatus(smsRequired = required, phoneVerified = verifiedPhone != null, maskedPhone = verifiedPhone?.let(::mask))
    }

    override suspend fun requestCode(purpose: SmsPurpose, invoiceId: String?, phone: String?, resend: Boolean): SmsChallenge = lock.withLock {
        val now = Instant.now()
        val number: String
        when (purpose) {
            SmsPurpose.SignInvoice, SmsPurpose.SignContract -> {
                if (!required) return SmsChallenge(required = false)
                val proven = verifiedPhone
                val ends = signingWindowEnds
                if (purpose == SmsPurpose.SignInvoice && ends != null && ends.isAfter(now) && proven != null) {
                    return SmsChallenge(required = false, maskedPhone = mask(proven), session = true)
                }
                number = when {
                    phone != null -> MobileNumber.e164(phone) ?: throw SmsException(SmsException.Kind.InvalidNumber)
                    proven != null -> proven
                    else -> throw SmsException(SmsException.Kind.PhoneNotVerified)
                }
            }
            SmsPurpose.VerifyPhone ->
                number = phone?.let(MobileNumber::e164) ?: throw SmsException(SmsException.Kind.InvalidNumber)
        }
        if (!resend && pending == number && pendingPurpose == purpose && attempts < 5) {
            return SmsChallenge(required = true, maskedPhone = mask(number), expiresAt = now.plusSeconds(600), reused = true)
        }
        attempts = 0
        pending = number
        pendingPurpose = purpose
        sent += 1
        SmsChallenge(required = true, maskedPhone = mask(number), expiresAt = now.plusSeconds(600))
    }

    override suspend fun confirm(purpose: SmsPurpose, code: String, invoiceId: String?): SmsConfirmation = lock.withLock {
        val number = pending
            ?: return SmsConfirmation(ok = false, reason = "expired", message = "Ce code a expiré. Demandez-en un nouveau.")
        if (attempts >= 5) return SmsConfirmation(ok = false, reason = "locked", message = "Trop d'essais. Demandez un nouveau code.")
        if (MobileNumber.code(code) != DEMO_CODE) {
            attempts += 1
            return if (attempts >= 5) SmsConfirmation(ok = false, reason = "locked", message = "Trop d'essais. Demandez un nouveau code.")
            else SmsConfirmation(ok = false, reason = "wrong", message = "Code incorrect.", attemptsLeft = 5 - attempts)
        }
        verifiedPhone = number   // either purpose proves the number
        if (purpose == SmsPurpose.SignInvoice) signingWindowEnds = Instant.now().plusSeconds(600)
        pending = null
        pendingPurpose = null
        SmsConfirmation(ok = true, maskedPhone = mask(number))
    }
}

fun Dependencies.sms(): SmsRepository = if (isDemo) DemoSms else SupabaseSmsRepository(requireClient())

/** The line under the code boxes in the demo, where no SMS is ever sent. */
val Dependencies.smsDemoHint: String? get() = if (isDemo) DemoSms.HINT else null
