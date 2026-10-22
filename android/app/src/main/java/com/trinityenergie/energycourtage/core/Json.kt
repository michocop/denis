package com.trinityenergie.energycourtage.core

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import java.math.BigDecimal
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** Supabase answers in snake_case; the models are camelCase, as on iOS
 *  (`convertFromSnakeCase`). Unknown keys are ignored so a new column on the
 *  server never breaks an installed app. */
@OptIn(ExperimentalSerializationApi::class)
val SupabaseJson = Json {
    namingStrategy = JsonNamingStrategy.SnakeCase
    ignoreUnknownKeys = true
    explicitNulls = false
    coerceInputValues = true
    isLenient = true
}

/** Dates as Supabase writes them: ISO-8601 with or without fractional seconds,
 *  with an offset or not, or a bare `yyyy-MM-dd` (UTC). The same three forms
 *  the iOS decoder tries, in the same order. */
object InstantSerializer : KSerializer<Instant> {
    override val descriptor = PrimitiveSerialDescriptor("Instant", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(value.toString())
    override fun deserialize(decoder: Decoder): Instant = parseInstant(decoder.decodeString())
}

fun parseInstant(raw: String): Instant {
    runCatching { return Instant.parse(raw) }
    runCatching { return java.time.OffsetDateTime.parse(raw).toInstant() }
    runCatching {
        return java.time.OffsetDateTime.parse(raw, DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss[.SSSSSS][.SSS]XXX")).toInstant()
    }
    runCatching { return java.time.LocalDateTime.parse(raw).toInstant(ZoneOffset.UTC) }
    return LocalDate.parse(raw.take(10)).atStartOfDay(ZoneOffset.UTC).toInstant()
}

/** Amounts: PostgREST sends `numeric` as a JSON number, sometimes as a string. */
object DecimalSerializer : KSerializer<BigDecimal> {
    override val descriptor = PrimitiveSerialDescriptor("BigDecimal", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: BigDecimal) = encoder.encodeString(value.toPlainString())
    override fun deserialize(decoder: Decoder): BigDecimal {
        val element = (decoder as? kotlinx.serialization.json.JsonDecoder)?.decodeJsonElement()
        val text = (element as? kotlinx.serialization.json.JsonPrimitive)?.content ?: decoder.decodeString()
        return BigDecimal(text)
    }
}
