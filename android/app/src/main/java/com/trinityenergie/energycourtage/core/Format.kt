package com.trinityenergie.energycourtage.core

import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/** SHA-256 of a text's UTF-8 bytes, lowercase hex: what the server stores
 *  for a legal document and checks an acceptance against (CryptoKit on iOS). */
fun sha256Hex(text: String): String = sha256Hex(text.toByteArray(Charsets.UTF_8))

fun sha256Hex(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

/** Dates the French way, in the phone's time zone. */
object Dates {
    private val zone get() = ZoneId.systemDefault()
    private val fr = Locale.FRANCE

    /** "5 oct. 2026" */
    fun medium(i: Instant): String = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(fr).format(i.atZone(zone))
    /** "5 oct. 2026 à 14:30" */
    fun mediumTime(i: Instant): String =
        DateTimeFormatter.ofPattern("d MMM yyyy 'à' HH:mm", fr).format(i.atZone(zone))
    /** "05/10/2026" */
    fun short(i: Instant): String = DateTimeFormatter.ofPattern("dd/MM/yyyy", fr).format(i.atZone(zone))
    fun short(d: LocalDate): String = DateTimeFormatter.ofPattern("dd/MM/yyyy", fr).format(d)
    /** "14:30" */
    fun time(i: Instant): String = DateTimeFormatter.ofPattern("HH:mm", fr).format(i.atZone(zone))

    /** "à l'instant", "il y a 5 min", "il y a 3 h", "hier", "il y a 4 j", then the date. */
    fun relative(i: Instant, now: Instant = Instant.now()): String {
        val s = (now.epochSecond - i.epochSecond).coerceAtLeast(0)
        return when {
            s < 60 -> "à l'instant"
            s < 3600 -> "il y a ${s / 60} min"
            s < 86_400 -> "il y a ${s / 3600} h"
            s < 172_800 -> "hier"
            s < 7 * 86_400 -> "il y a ${s / 86_400} j"
            else -> medium(i)
        }
    }
}
