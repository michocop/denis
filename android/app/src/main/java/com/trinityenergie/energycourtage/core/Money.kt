package com.trinityenergie.energycourtage.core

import java.math.BigDecimal
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale

/** Euros as they are written in France: "1 500 €", "12 500,50 €". The narrow
 *  no-break space Java groups French thousands with is not in Sora or
 *  Manrope, so it becomes a plain no-break space -- the same fix as iOS. */
object Money {
    fun euros(amount: BigDecimal, cents: Boolean = false): String {
        val f = NumberFormat.getCurrencyInstance(Locale.FRANCE).apply {
            currency = Currency.getInstance("EUR")
            minimumFractionDigits = if (cents) 2 else 0
            maximumFractionDigits = if (cents) 2 else 0
        }
        return f.format(amount).replace(' ', ' ')
    }
}
