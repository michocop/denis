package com.trinityenergie.energycourtage.model

import com.trinityenergie.energycourtage.core.InstantSerializer
import kotlinx.serialization.Serializable
import java.time.Instant

/** What a code sent by SMS is for. The server binds each code to one purpose
 *  (and, for a signature, to one invoice), so a code cannot be reused. */
enum class SmsPurpose(val raw: String) {
    VerifyPhone("verify_phone"),
    SignInvoice("sign_invoice"),
    /** The apporteur contract and its annex, signed once at the first sign-in. */
    SignContract("sign_contract"),
}

/** Whether signing needs a code, and whether this person can receive one. */
@Serializable
data class SmsStatus(
    /** False until the company has set SMS up; signing then needs no code. */
    val smsRequired: Boolean = false,
    val phoneVerified: Boolean = false,
    val maskedPhone: String? = null,
)

/** A code on its way. */
@Serializable
data class SmsChallenge(
    /** False when no code is needed: the action goes ahead without one --
     *  SMS is not set up, or a code confirmed minutes ago still covers it. */
    val required: Boolean,
    val maskedPhone: String? = null,
    @Serializable(InstantSerializer::class) val expiresAt: Instant? = null,
    /** A code confirmed in the last ten minutes covers this signature. */
    val session: Boolean? = null,
    /** The code already sent is still good, so no new SMS went out. */
    val reused: Boolean? = null,
)

/** The server's answer to a code. A wrong code is an answer, not an error:
 *  it is counted, and five of them retire the code. */
@Serializable
data class SmsConfirmation(
    val ok: Boolean,
    /** "wrong", "expired" or "locked" when [ok] is false. */
    val reason: String? = null,
    val message: String? = null,
    val attemptsLeft: Int? = null,
    val maskedPhone: String? = null,
) {
    /** This code can no longer be used: only a new one will do. */
    val needsNewCode get() = reason == "expired" || reason == "locked"
}

/** Where a signature stands between "Signer" and the signature: a number to
 *  give first (its code then proves it and signs, one SMS), or a code on its
 *  way to the number already proven. */
sealed interface SigningStep {
    data object EnterPhone : SigningStep
    data class EnterCode(val maskedPhone: String) : SigningStep
}

class SmsException(kind: Kind) : Exception(kind.message) {
    enum class Kind(val message: String) {
        PhoneNotVerified("Indiquez votre numéro de mobile."),
        InvalidNumber("Ce numéro de mobile n'est pas valide."),
    }
}

/** Mobile numbers as the server understands them (`normalise_mobile`), so the
 *  app can tell a typo from a number before anything is sent. */
object MobileNumber {
    private fun isDigits(s: String) = s.isNotEmpty() && s.all { it in '0'..'9' }

    /** E.164 for a French mobile however it is typed, or any international
     *  number given with its + prefix; null otherwise. */
    fun e164(raw: String): String? {
        var v = raw.filter { it !in " .-() " }
        if (v.startsWith("00")) v = "+" + v.drop(2)
        if (v.length == 10 && (v.startsWith("06") || v.startsWith("07")) && isDigits(v)) v = "+33" + v.drop(1)
        if (v.length == 11 && (v.startsWith("336") || v.startsWith("337")) && isDigits(v)) v = "+$v"
        if (!v.startsWith("+") || !isDigits(v.drop(1))) return null
        val digits = v.drop(1)
        if (digits.startsWith("33")) {
            return if (digits.length == 11 && (digits.drop(2).startsWith("6") || digits.drop(2).startsWith("7"))) v else null
        }
        return if (digits.length in 8..15 && !digits.startsWith("0")) v else null
    }

    /** A French number as it is written, in pairs: "06 12 34 56 78". Anything
     *  typed with a + is left as typed. */
    fun formatted(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.startsWith("+")) return raw
        val digits = trimmed.filter { it in '0'..'9' }.take(10)
        if (!digits.startsWith("0")) return digits
        return digits.chunked(2).joinToString(" ")
    }

    /** Only the digits of a code, at most six: what a paste or the keyboard's
     *  one-time-code suggestion fills in. */
    fun code(raw: String): String = raw.filter { it in '0'..'9' }.take(6)
}
