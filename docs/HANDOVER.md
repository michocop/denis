# Handover checklist

What has to be true before this is the client's, not yours. Ordered by what
blocks what. "You" is whoever is building; "the client" is Trinity Énergie.

---

## 1. It works

| | Owner | Est. |
|---|---|---|
| ~~First compile~~ — **done.** CI builds the package on a macOS runner and runs its 24 tests on every push | — | — |
| **Run against a real Supabase project** — every network path is still theoretical | You + me | 2 d |
| Supabase project created, `supabase db push` applied, seed loaded | You | 1 h |
| App runs on a real device against the real project | You | 0.5 d |
| Every screen walked by hand on device: create a reco, advance it, issue an invoice, sign both sides, open a conversation, schedule a reminder | You | 1 d |
| The four remaining screens reworked to match the real app | You, once screenshots arrive | 6 d |

The backend is verified (134 assertions) and the app compiles with its tests
passing. What has never happened is the two talking to each other: no request
this client makes has ever reached a real PostgREST. That is now the largest
single unknown, and it is the next thing worth doing.

## 2. It matches

- The real typeface (currently SF, appears to be a geometric sans) — 1 line
- Exact brand hexes, sampled from source rather than from compressed screenshots
- Screens still built from inference, not from your app: **Accueil, Profil,
  create-recommendation, Archivées, a lost/refused reco, wizard steps 2–5**

## 3. The client can run it without you

This is the part most handovers get wrong.

| | Why it matters |
|---|---|
| **The Supabase project is created under the client's own account**, not yours | Otherwise the database — including every apporteur's personal data — sits in a personal account they cannot access if you disappear |
| **The Apple Developer account is enrolled as Trinity Énergie** (organisation, needs a D-U-N-S number), not as you personally | An app published under your personal account is legally your app. Transferring later is possible but painful, and the D-U-N-S takes 1–2 weeks to obtain — **start this first, it is the longest lead time in the project** |
| Credentials handed over properly: Supabase, Apple, any email sender | Not over chat. A password manager vault they own |
| At least one client-side admin exists in `profiles` with `role = 'admin'` | Otherwise nobody can invite anyone |
| The repository transferred to an account they control | |
| A written note of what breaks if nobody maintains it | Honest scope of ongoing support |

## 4. It is lawful

None of this is optional, and it runs in **parallel** with the code — a lawyer
takes 1–2 weeks of calendar time, so starting it after the app is done adds
two weeks to the date.

| | Status |
|---|---|
| **Mandat de facturation** — the document each apporteur signs before the company can invoice in their name | Enforced in the database; **the document itself does not exist yet** |
| **CGU** | Not written |
| **Privacy policy** covering the filleul, who never signed up | Not written |
| **RGPD register of processing** (registre des traitements) | Not written |
| **DPA with Supabase**, and confirmation the project is hosted in the EU | Not done — check the region when creating the project |
| Retention policy: how long a lost lead's personal data is kept | Not decided |
| Lawyer review of the self-billing arrangement and the apporteur's status | Not done |

## 5. It can be distributed

- Apple Developer enrolment (see §3) — 24–48 h personal, **1–2 weeks as an organisation**
- App icon and launch screen — neither exists
- `PrivacyInfo.xcprivacy` privacy manifest
- App Store Connect privacy answers (data collected: contact info, identifiers, usage)
- TestFlight build to the first apporteurs
- Support contact and a way for users to report problems

## 6. It survives contact with users

- What happens when an apporteur forgets their password *and* changes email
- Who watches for failed payouts
- What the client does when an invoice is issued wrongly (answer: a credit note
  — the code refuses to edit a signed invoice, by design)
- A backup and restore that someone has actually tested

---

## Operating runbook

### Adding an apporteur
An admin calls `create_invite(email, role, auto_activate)` and reads them the
code. `auto_activate = false` parks them in *pending* until an admin calls
`approve_member`. There is no open sign-up, by design.

### Correcting an invoice
A signed invoice cannot be edited or deleted; French law requires keeping it
ten years. Issue a credit note (avoir) and a corrected invoice. The database
enforces this — it is not a setting.

### Someone was invoiced without a mandate
Impossible: `invoices` refuses the insert. If an apporteur cannot be paid,
check `profiles.billing_mandate_signed_at`.

### An apporteur crosses the VAT threshold
Set `profiles.vat_liable = true` and add their VAT number. Every subsequent
invoice carries 20 % automatically; earlier ones are untouched, correctly.

### A lead is claimed by two apporteurs
`check_duplicate_filleul` warns at creation but never blocks a contested lead —
that is a commercial decision. The audit log records who submitted first.

### Restoring confidence in the security model
`scripts/db_test.sh` runs the whole RLS suite against a throwaway database.
Run it after any schema change. A failing assertion means data is exposed.

---

## Shortest honest path to a handover

1. **Today:** start the Apple organisation enrolment (D-U-N-S), create the
   Supabase project in an EU region under the client's account, and brief a
   lawyer. All three have lead times you cannot compress.
2. **This week:** first compile, app running on a device against real data.
3. **Next two weeks:** the four unseen screens, device testing, icon, manifest.
4. **Week four:** legal texts in, TestFlight to real apporteurs, fix what they hit.

The code is the part most under control. The lead times in step 1 are what
decide the date.
