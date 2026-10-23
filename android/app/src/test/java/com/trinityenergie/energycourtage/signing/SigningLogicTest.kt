package com.trinityenergie.energycourtage.signing

import com.trinityenergie.energycourtage.core.sha256Hex
import com.trinityenergie.energycourtage.data.DemoLegalTexts
import com.trinityenergie.energycourtage.data.DemoSms
import com.trinityenergie.energycourtage.model.ApporteurContract
import com.trinityenergie.energycourtage.model.BusinessStatus
import com.trinityenergie.energycourtage.model.LegalText
import com.trinityenergie.energycourtage.model.LegalText.Block
import com.trinityenergie.energycourtage.model.MobileNumber
import com.trinityenergie.energycourtage.model.SmsException
import com.trinityenergie.energycourtage.model.SmsPurpose
import com.trinityenergie.energycourtage.model.plainRate
import com.trinityenergie.energycourtage.pdf.PdfText
import com.trinityenergie.energycourtage.ui.onboarding.groupedSiret
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.math.BigDecimal
import java.time.Instant

class MobileNumberTest {
    @Test fun frenchMobilesHoweverTyped() {
        assertEquals("+33612345678", MobileNumber.e164("06 12 34 56 78"))
        assertEquals("+33712345678", MobileNumber.e164("07.12.34.56.78"))
        assertEquals("+33612345678", MobileNumber.e164("0033 6 12 34 56 78"))
        assertEquals("+33612345678", MobileNumber.e164("33612345678"))
        assertEquals("+33612345678", MobileNumber.e164("+33 (0)6-12-34-56-78".replace("(0)", "")))
        assertEquals("+33612345678", MobileNumber.e164("06 12 34 56 78"))
    }

    @Test fun refusesWhatIsNotAMobile() {
        assertNull(MobileNumber.e164("01 23 45 67 89"))      // a landline
        assertNull(MobileNumber.e164("+33123456789"))        // French, not 6 or 7
        assertNull(MobileNumber.e164("0612"))
        assertNull(MobileNumber.e164("+0612345678"))
        assertNull(MobileNumber.e164("+"))
        assertNull(MobileNumber.e164("abc"))
        assertNull(MobileNumber.e164("+٣٣٦١٢٣٤٥٦٧٨"))          // non-ASCII digits
    }

    @Test fun internationalWithItsPlus() {
        assertEquals("+4915112345678", MobileNumber.e164("+49 151 12345678"))
        assertEquals("+32470123456", MobileNumber.e164("0032 470 12 34 56"))
        assertNull(MobileNumber.e164("+1234567"))            // 7 digits: too short
    }

    @Test fun formattedInPairs() {
        assertEquals("06 12 34 56 78", MobileNumber.formatted("0612345678"))
        assertEquals("06 12 3", MobileNumber.formatted("06123"))
        assertEquals("+33 6 12", MobileNumber.formatted("+33 6 12"))
        assertEquals("612", MobileNumber.formatted("612"))
        assertEquals("", MobileNumber.formatted(""))
    }

    @Test fun codeKeepsSixDigits() {
        assertEquals("123456", MobileNumber.code(" 12-34 56 78"))
        assertEquals("12", MobileNumber.code("a1b2"))
    }
}

class LegalTextTest {
    @Test fun parsesHeadingsBulletsAndParagraphs() {
        val blocks = LegalText.parse("""
            ## Article 1 — Objet

            Le présent contrat
            définit les conditions.

            - premier point ;
            • second point.
            Article 3 — Durée
            Suite du texte.
        """.trimIndent())
        assertEquals(listOf(
            Block.Heading("Article 1 — Objet"),
            Block.Paragraph("Le présent contrat définit les conditions."),
            Block.Bullet("premier point ;"),
            Block.Bullet("second point."),
            Block.Heading("Article 3 — Durée"),
            Block.Paragraph("Suite du texte."),
        ), blocks)
    }

    @Test fun aLongArticleSentenceIsAParagraph() {
        val line = "Article 12 dispose que " + "x".repeat(80)
        assertEquals(listOf(Block.Paragraph(line)), LegalText.parse(line))
        // "Article 1er" is not "Article <n>" on a word boundary
        assertEquals(listOf(Block.Paragraph("Article1 collé")), LegalText.parse("Article1 collé"))
    }

    @Test fun boldRuns() {
        assertEquals(
            listOf(LegalText.Run("TRINITY", true), LegalText.Run(", SAS et ", false), LegalText.Run("Et", true)),
            LegalText.runs("**TRINITY**, SAS et **Et**"),
        )
        assertEquals(listOf(LegalText.Run("sans gras", false)), LegalText.runs("sans gras"))
    }

    @Test fun demoTextsAreTheIosBytes() {
        // computed from ios/Sources/EnergyCourtage/Preview/SampleData.swift
        assertEquals("add7a88e3981a247c017bd640d6fee4155336cce30471ddb0c00f9d5634d96c2", sha256Hex(DemoLegalTexts.contract))
        assertEquals("1f9374fbf11f87931a6d0620307bb31cdf690cae676ec78e343afc05953ea4a3", sha256Hex(DemoLegalTexts.mandate))
    }
}

class PdfTextTest {
    @Test fun moneyTheFrenchWay() {
        assertEquals("300,00 €", PdfText.money("300.00", "EUR"))
        assertEquals("12 500,50 €", PdfText.money("12500.50", "EUR"))
        assertEquals("-1 234 567,00 €", PdfText.money("-1234567.00", "EUR"))
        assertEquals("15,00 USD", PdfText.money("15", "USD"))
    }

    @Test fun digestInGroupsOfEight() {
        assertEquals("6b3788b6 c0f4de8a", PdfText.grouped("6b3788b6c0f4de8a"))
        assertEquals("document non scellé", PdfText.grouped(null))
    }

    @Test fun wrapsOnWordsAndKeepsNewlines() {
        val measure = { s: String -> s.length.toFloat() }
        assertEquals(listOf("aa bb", "cc"), PdfText.wrap("aa bb cc", 5f, measure))
        assertEquals(listOf("averylongword", "x"), PdfText.wrap("averylongword x", 5f, measure))
        assertEquals(listOf("a", "", "b"), PdfText.wrap("a\n\nb", 5f, measure))
    }

    @Test fun vatRateWithoutTrailingZeros() {
        assertEquals("0", BigDecimal("0.00").plainRate())
        assertEquals("20", BigDecimal("20.00").plainRate())
        assertEquals("5.5", BigDecimal("5.50").plainRate())
    }

    @Test fun siretInGroups() {
        assertEquals("123 456 789 00011", groupedSiret("12345678900011"))
        assertEquals("1234", groupedSiret("1234"))
    }

    @Test fun contractReference() {
        val c = ApporteurContract("5f0c2a1e-1111-2222-3333-444444444444", "p", Instant.EPOCH, BusinessStatus.Societe, "1", "X")
        assertEquals("CT-5F0C2A1E", c.reference)
        assertEquals("Contrat apporteur CT-5F0C2A1E.pdf", c.fileName)
    }
}

class DemoSmsTest {
    @Test fun aWrongCodeIsCountedAndFiveLockIt() = runTest {
        DemoSms.reset(required = true)
        val challenge = DemoSms.requestCode(SmsPurpose.VerifyPhone, null, "06 12 34 56 78")
        assertTrue(challenge.required)
        assertEquals("+33 6 •• •• •• 78", challenge.maskedPhone)
        val wrong = DemoSms.confirm(SmsPurpose.VerifyPhone, "000000", null)
        assertFalse(wrong.ok)
        assertEquals("wrong", wrong.reason)
        assertEquals(4, wrong.attemptsLeft)
        repeat(3) { DemoSms.confirm(SmsPurpose.VerifyPhone, "000000", null) }
        val locked = DemoSms.confirm(SmsPurpose.VerifyPhone, "000000", null)
        assertEquals("locked", locked.reason)
        assertTrue(locked.needsNewCode)
    }

    @Test fun theCodeProvesTheNumberAndOpensASigningWindow() = runTest {
        DemoSms.reset(required = true)
        try {
            DemoSms.requestCode(SmsPurpose.SignInvoice, "inv", null)
            fail("no number yet")
        } catch (e: SmsException) {
            assertEquals("Indiquez votre numéro de mobile.", e.message)
        }
        DemoSms.requestCode(SmsPurpose.SignInvoice, "inv", "0712345678")
        // asked again: the code on its way is reused, no second SMS
        assertEquals(true, DemoSms.requestCode(SmsPurpose.SignInvoice, "inv", "0712345678").reused)
        assertEquals(1, DemoSms.sent)
        assertTrue(DemoSms.confirm(SmsPurpose.SignInvoice, DemoSms.DEMO_CODE, "inv").ok)
        assertTrue(DemoSms.status().phoneVerified)
        val next = DemoSms.requestCode(SmsPurpose.SignInvoice, "inv2", null)
        assertFalse(next.required)
        assertEquals(true, next.session)
    }

    @Test fun noCodeWhenSmsIsNotSetUp() = runTest {
        DemoSms.reset(required = false)
        assertFalse(DemoSms.requestCode(SmsPurpose.SignContract, null, null).required)
        DemoSms.reset()
    }
}
