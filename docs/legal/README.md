# Legal documents

The texts the app asks people to accept live in the database, versioned
(`supabase/seed/trinity_energie.sql`); the `.md` files here are the earlier
drafts with `[PLACEHOLDERS]`, kept for history. **The published versions are
the `2026-10-1` rows in the seed**, filled in with TRINITY ENERGIE's real
details.

| Document | Where | Status |
|---|---|---|
| Mandat de facturation | seed, `mandat_facturation` 2026-10-1 | Filled in; published once activated. Blocks invoicing until each apporteur signs it |
| CGU | seed, `cgu` 2026-10-1 | Filled in; required by the App Store |
| Politique de confidentialité | seed, `confidentialite` 2026-10-1 | Filled in; names Supabase, Brevo and Apple as recipients |
| Registre des traitements | `registre-traitements.md` | Filled in from what the code does; internal, not published |

They have **not** been through a lawyer. Publishing them now is still better
than publishing nothing: with no apporteur signed up yet, a corrected version
costs nothing, since the app asks everyone to accept the new version before
going on (and keeps who accepted which, with its digest).

## Contracts with processors (DPA, art. 28 RGPD)

Nothing to sign for the two that hold the data: each one's DPA is part of the
terms accepted when the account was opened.

- **Supabase** — [supabase.com/legal/dpa](https://supabase.com/legal/dpa), in force
  with the terms of service; the project is in Paris (eu-west-3). For a signed
  copy to file, download it and send it signed to privacy@supabase.com. Make
  sure the Supabase account itself belongs to TRINITY ENERGIE (it is the
  contracting party).
- **Brevo** — French, EU-hosted; the DPA is an annex of
  [its terms](https://www.brevo.com/legal/termsofuse/).
- **Apple (push)** — covered by the Apple Developer Program agreement, signed
  when the developer account is opened. Whether that suffices for the content
  of notifications is question 6 below.

## What to ask the lawyer

Send them the three texts (export from the seed), `registre-traitements.md`,
and these questions. Ask for a **fixed-fee quote** for the review: it is a
bounded job.

1. **The relationship.** Is the apport d'affaires correctly characterised?
   Any risk of requalification as employment or as commercial agency (agent
   commercial, with its end-of-contract indemnity)?
2. **The self-billing mandate.** Does it meet art. 289 I-2 CGI: a prior
   written mandate, the apporteur's acceptance of each invoice (the app has
   them sign it), the mention « Autofacturation » on the invoice, and a way to
   contest one?
3. **Apporteurs who are private individuals** (not micro-entrepreneurs):
   can they be paid at all, under what tax and social treatment, and what must
   the company check or declare?
4. **The filleul's data.** Legitimate interest with art. 14 information within
   a month (what the texts say now), or consent?
5. **Energy brokerage rules.** Any obligation specific to courtage en énergie
   (mandate, transparency of the broker's remuneration, the code de la
   consommation for professional customers)?
6. **Push notifications.** Their text (a filleul's name, a stage) passes
   through Apple's servers, possibly outside the EU. Is Apple a processor or a
   recipient here, and is the transfer adequately covered?
7. **Retention.** Are 36 months for a lost lead, 3 years after the end of the
   relationship and 10 years for invoices right?

## Ask the accountant (expert-comptable)

Quicker and usually included in their fee:

- **DAS2**: commissions paid to an apporteur above 1 200 € a year are normally
  declared on the DAS2. Confirm, and who files it.
- VAT on commissions: apporteurs in franchise (art. 293 B) versus liable — the
  app handles both, but the accountant should confirm the mentions on the PDF.
- That the invoice PDF and its numbering suit their bookkeeping.

## Free resources

- CNIL: the guide RGPD pour les TPE/PME and its registre template — the
  registre here follows the same structure.
- CNIL: a model notice for data collected indirectly (art. 14), for the first
  call to a filleul.
