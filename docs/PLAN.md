# Energy Courtage — Apporteur d'Affaires Platform
## Clone analysis + full build plan (v3 — screenshot batches #1 + #2 + #3)

> Status: **living document**. v3 adds the Catalogue (with admin CRUD and a multi-step
> product wizard) and the Chat screen (which revealed a **group + ticketing** system).
> Sections marked `❓ TO CONFIRM` are still assumptions.
>
> **See §0 for what each batch changed, and §11 for the "can we do it in a weekend?" answer.**

---

## 0. What batch #2 changed

| v1 assumption | v2 reality | Impact |
|---|---|---|
| Screenshots are the collaborator app | **They are the ADMIN app.** "Valider l'étape", "Réassigner", "Supprimer", and *"Vous allez signer en tant que Pierre-Louis TETTAMANTI"* (Trinity Énergie = the company) are all company-side | Rethink the two-app split — see §3.1 |
| Contracts are signed outside and uploaded | **Dual e-signature happens in-app**, apporteur + entreprise | +6 to +12 days, plus real legal weight |
| "Voir le contrat" = the energy supply contract | It is the **facture / attestation d'apport d'affaires** between the company and the apporteur | A whole invoicing module appears in scope |
| Network might be multi-level | Vocabulary is **parrain → filleul**, where the *filleul is the recommended prospect*, not a sub-collaborator. Flat network | Removes the 2-3 week multi-level risk 🎉 |
| (v3) Chat = one realtime screen | Chat has **groups, pinning, archiving, unread filters AND a separate `Tickets` system** | 9 d → 15 d |
| (v3) Catalogue = a read-only list | Catalogue has **admin CRUD and a ~5-step product wizard** | 4 d → 7 d |

---

## 1. What the product actually is

An **energy brokerage referral platform**, built around a single object — the
`recommandation` — seen from two sides.

| Role | Who | What they do |
|---|---|---|
| **Apporteur / Parrain** | Independent business introducer (Johann Lefeuvre) | Submits a **filleul** (lead), follows the pipeline read-only, signs his invoice, gets paid |
| **Entreprise / Admin** | The brokerage (Pierre-Louis Tettamanti — Trinity Énergie) | Advances the pipeline, comments at each stage, generates and co-signs the invoice, reassigns, reminds, archives |

### The money flow, now fully visible
```
Reco créée → À contacter → RDV programmé → Proposition envoyée
   → Devis signé 🎁 (commission earned)
   → Mission terminée → facture d'apport générée → double signature → virement
```
The final stage comment literally says: *"nous allons procéder au paiement de vos honoraires…
n'oubliez pas de procéder à votre déclaration de revenu… bénéfices non commerciaux (BNC)
via votre déclaration de revenus - CERFA 2042 C"*. So the product also plays a **tax-guidance**
role toward the apporteur. That copy is a template — keep it editable, tax rules change.

---

## 2. Screen inventory & spec

### 2.1 `Recommandations` list — completed reco (batch 1, shot 1)

Card = header (client, "Recommandé par X", timestamp, **amount in green**, chevron)
+ green status banner + 5-stage vertical stepper + `Notes personnelles` + `Voir le contrat`
+ `Voir plus`.

### 2.2 `Recommandations` list — **in-progress reco** (batch 2, shot 5) ⭐

This is the shot that unlocks the stepper state machine:

| State | Circle | Label | Connector below |
|---|---|---|---|
| **Completed** | filled green `#22C55E`, white check | `textPrimary` | solid green |
| **Current** | white fill, 2 pt blue ring `#2196D3`, blue centre dot | `textPrimary` | thin grey |
| **Pending** | white fill, 1 pt grey ring `#D1D5DB`, small grey dot | grey `#9CA3AF` | thin grey `#E5E7EB` |

Also confirmed here:
- **No amount and no status banner** on a reco that hasn't reached the reward stage.
  The green `1000 €` appears only once the reward is triggered. `❓ CONFIRM` (or is it simply
  that the amount is set later by the admin?)
- **The 💬 bubble only renders when a comment exists** — only `À contacter` has one.
- The `🎁 Récompense` badge is **static config on the stage**, shown even when pending.
- Footer becomes two buttons: `Voir plus` (secondary grey) + **`Valider l'étape`** (primary blue)
  — the admin's pipeline-advance action.
- A **realtime refresh banner**: white pill, `De nouveaux éléments sont di…` + blue
  `🔄 Actualiser` button. Push/realtime tells the list it is stale rather than
  auto-reloading under the user's finger. Good pattern — keep it, but fix the truncation.

### 2.3 Stage comment modal (batch 1 shots 2-4, batch 2 shot 1)

Centered dialog, dimmed backdrop, 💬 circle icon, two-line title
`Commentaire pour l'étape` / `"<stage>"`, `Message` label, read-only grey block, blue `Fermer`.

**The comments are templated** — same voice, client/apporteur name injected:

| Stage | Template (reconstructed) |
|---|---|
| À contacter | « Merci pour la mise en relation. Nous avons bien reçu les coordonnées de `{filleul}`. Prochain point après le 1er échange. » |
| RDV programmé | « J'ai contacté `{filleul}`. Le rendez-vous est planifié. Je vous tiens informé(e) de la suite. » |
| Proposition envoyée | « J'ai transmis à `{filleul}` la proposition. Retour attendu très prochainement. » |
| Devis signé | `❓ not yet seen` |
| Mission terminée | « Bonjour `{parrain}`, Je vous informe que nous allons procéder au paiement de vos honoraires… BNC… CERFA 2042 C… » |

⇒ Build a `stages.comment_template` field with `{filleul}` / `{parrain}` / `{montant}`
interpolation, pre-filled and editable at validation time.

### 2.4 **Facture / attestation d'apport d'affaires** (batch 2, shots 2-3) ⭐⭐

A scrollable generated document, then a signature panel.

```
Pierre-Louis Tettamanti              ← émetteur (entreprise)
Trinity Énergie
AIX-EN-PEVELE
                        Johann Lefeuvre   ← apporteur, right-aligned

            • Numéro de facture 1111

Je soussigné : Johann Lefeuvre
Atteste avoir mis en relation : Trinity Énergie
Avec : Thomas Dubois
Pour la prestation suivante : aa          ← free-text, here filled with test data
Intervenue le : 17.09.2026
────────────────────────────────
Montant de la prestation : 300.00 EUR
────────────────────────────────
TVA non applicable – Régime d'exonération de TVA (Article 293B du CGI)
Modalité de règlement : Virement bancaire
Fait à : AIX-EN-PEVELE
Le : 17.09.2026
<bloc rappel fiscal BNC / CERFA 2042 C>
Signatures :
        Johann Lefeuvre
        Pierre-Louis Tettamanti
```

Then a separate card:
```
VOUS ALLEZ SIGNER EN TANT QUE
Pierre-Louis TETTAMANTI
──────────────────────────────
✅ Signature de l'apporteur      signé
✅ Signature de l'entreprise     signé
```
and a `Fermer` text button bottom-right.

**Fields to model:** `invoice_number`, `issuer` (company + city), `apporteur`, `filleul`,
`prestation_label`, `intervened_on`, `amount`, `vat_regime`, `payment_method`, `place`,
`issued_on`, `tax_notice_template`, `signatures[]`.

**Inconsistency to resolve:** the card shows `1000 €`, the invoice shows `300.00 EUR`.
Either demo data, or reward-shown-to-apporteur and invoiced-amount are two distinct fields.
`❓ CONFIRM — this matters, it's the money.`

### 2.5 Reco action sheet (batch 2, shot 4)

Bottom sheet, rounded top ~24, drag-to-dismiss + ✕:
```
Thomas Dubois
Recommandé par Johann Lefeuvre
17/09/2026 à 14:57

Informations filleul
📞 +33 6 75 75 75 75              ›     ← tap to call
ⓘ 2026-09-17
ⓘ invoice_number                        ← ⚠️ raw key leaking (see §2.6)

┌─────────────────────────┐
│ ⇄  Réassigner           │
│ 🔔 Rappels              │
│ ↺  Remettre à zéro      │
│ 🗄  Archiver            │
│ 🗑  Supprimer  (rouge)   │
└─────────────────────────┘
```
Five admin powers, four of which need confirmation + audit logging.
`Remettre à zéro` (reset the whole pipeline) is the most dangerous — it destroys stage
history unless you soft-reset. `Supprimer` must be blocked once an invoice exists (§6.2).

### 2.6 `Catalogue` (batch 3, shots 1-3)

Large title `Catalogue` · search `Rechercher un produit…` · category chips
(`Tous` selected = blue border + blue text + pale blue fill, `Energie` = grey outline) ·
blue **FAB `+`** bottom-right · product cards:

```
┌────────────────────────────────┐
│ [ 16:9 image ]        ✏️  🗑    │  ← edit / delete float over the image (ADMIN only)
│ Suivi              [En stock]  │  ← green pill
│ Nous surveillons vos dates     │
│ d'échéances…                   │  ← 2-line description
│ 🏷 Energie          Sur devis  │  ← category + price, price in brand blue
└────────────────────────────────┘
```
Products seen: **Suivi**, **Optimisation**, **Conseil** — all `Energie`, all `Sur devis`.
So the catalogue sells *services of the brokerage*, not energy contracts. Pricing is
`Sur devis`, meaning `offers.price_mode = enum('quote','fixed')` rather than a number.

### 2.7 Add-product wizard (batch 3, shot 4)

Back chevron + **progress bar (~20% ⇒ roughly 5 steps)** · `Informations sur le produit` /
`Saisissez les détails du produit que vous souhaitez mettre en ligne` ·
`Nom du produit` (text) · `Catégorie` (dropdown) · footer `Annuler` + `Suivant` (disabled
until valid). Remaining steps `❓ not yet seen` — presumably description, image, pricing,
reward amount, publish.

### 2.8 `Chat` (batch 3, shot 5) ⭐ bigger than v2 assumed

```
Chat
[ Discussions | Tickets ]            ← ⚠️ a support TICKETING system, new module
🔍 Rechercher une discussion   [✎]   ← compose
( Toutes ) ( Non lues ) ( Groupes ) ( Épinglées ) ( Arch…   ← scrollable filter chips
┌──────────────────────────────────┐
│ (JL)  Johann Lefeuvre      14:56 │
│       Aucun message          ⋯   │
└──────────────────────────────────┘
```
Confirmed scope: 1:1 **and group** conversations, pin, archive, unread filter, per-thread
overflow menu, compose flow, **plus a separate ticket system** with its own lifecycle
(status, assignee, priority, resolution). That is not "a chat screen", it is two modules.

### 2.9 Bugs in the original — **do not clone these**
1. `invoice_number` displayed as a raw field key instead of a label + value.
2. `De nouveaux éléments sont di…` truncated instead of wrapping or shortening.
3. `Pour la prestation suivante : aa` — no validation on a field that lands on a legal document.
4. `1000 €` vs `300.00 EUR` mismatch on the same reco.
5. Invoice number `1111` — sequential numbering is a **legal obligation** (§6.2).
6. The invoice header mixes the company and the apporteur with ambiguous alignment; a real
   invoice needs SIRET, address and legal form of both parties.
7. The Catalogue **FAB overlaps card content** — `Sur devis` is hidden behind the `+` button.
   Needs bottom content inset.
8. All three products use the **same stock photo**.
9. `En stock` on a service sold `Sur devis` — inventory semantics applied to something with no
   inventory. Prefer `Disponible` / `Actif`.
10. The `Arch…` filter chip is clipped rather than scrolled into view.

### 2.10 Design tokens (sampled — refine against the real source)
```swift
brandBlue     #2196D3   // tint, primary button, current-step ring, links
successGreen  #22C55E   // completed circles/lines, ✅ in signature panel
successText   #16A34A   // "1000 €", banner text
successBg     #DCFCE7
rewardBg      #FEF3C7 · rewardText #B45309      // 🎁 Récompense
destructive   #FF3B30                            // Supprimer
textPrimary   #111827 · textSecondary #9CA3AF
pendingRing   #D1D5DB · connectorIdle #E5E7EB
surface       #FFFFFF · trackGrey #F1F2F4 · groupedBg #F2F2F7 (action list)

radii: card 16-20 · search 14 · segmented 12/14 · button 12 · modal 24 · sheet 24 (top) · pill ∞
type: geometric sans (Poppins / Figtree family ❓ confirm) — title 28-30 semibold,
      cardTitle 22 semibold, body 17, secondary 16, sectionCaps 13 letterSpaced
grid: 4/8 pt · gutters 16 · card padding 20
```

---

## 3. Tech stack

### 3.1 Revised architecture (v2)

v1 said "admin = web only". Batch #2 proves the admin works **from a phone**, and the actions
are genuinely mobile-friendly (validate a stage on the road, sign an invoice, call the filleul).
So:

| Surface | What | Why |
|---|---|---|
| **One iOS app, two role-gated UIs** (SwiftUI, iOS 17+) | Same list, same card, same stepper, same modals. Admin additionally sees `Valider l'étape`, the action sheet, the comment composer and the company signature panel | The two sides share ~80% of the UI. Two separate apps would duplicate the design system, the models and the networking for nothing. Role gating is a `if session.role == .admin` on a handful of views |
| **Next.js 15 web back-office** (React, TS, Tailwind, shadcn/ui) | The heavy desk work only: user approval & KYC, catalogue CMS, commission batches & SEPA/CSV export, invoice archive, analytics, template editing | Tables, bulk actions and exports are miserable on a phone, and this ships without App Review |
| **Supabase** (Postgres + Auth + RLS + Storage + Realtime + Edge Functions) | Backend | Relational data; RLS enforces "an apporteur sees only his own recos" *in the database* — the single most important security property here |
| **PDF** | Server-side render in an Edge Function (`@react-pdf` or Typst/wkhtmltopdf) | The invoice is a legal artefact — it must be generated **once, server-side, immutably**, not re-rendered by each client |
| **Push** | APNs via Edge Function | |

### 3.2 The alternative
If Android is needed within 12 months → **Expo (React Native) + Next.js in a TS monorepo**,
sharing types, Zod schemas, API client and invoice logic. Saves ~25-30% of total. Given you're
solo, genuinely worth considering. The plan below assumes SwiftUI as you asked.

### 3.3 iOS module map
```
App/            routing, deep links, session, role gating
DesignSystem/   tokens · Card · Stepper(4 states) · StatusBanner · RewardBadge
                SegmentedControl · SearchField · AlertModal · ActionSheet
                RefreshBanner · SignaturePanel
Core/           Networking (Supabase) · Auth · SwiftData cache · Push · PDFKit
Features/       Home · Recommendations · Invoices · Catalogue · Chat · Profile · Admin
```
MVVM with `@Observable`, `async/await`, protocol-based repositories so every view model is
testable against a fake.

---

## 4. Data model (Postgres)

```sql
profiles(id uuid pk → auth.users, role enum('apporteur','admin','manager'),
         first_name, last_name, phone, email, avatar_url,
         company_name, siret, legal_form, address, city,
         vat_liable bool default false,        -- drives the 293B mention
         iban_encrypted, kyc_status, status enum('pending','active','suspended'), created_at)

recommendations(id uuid pk,
         filleul_first_name, filleul_last_name, filleul_phone, filleul_email,
         filleul_company, filleul_siret, filleul_address,
         parrain_id uuid → profiles,            -- "Recommandé par Johann Lefeuvre"
         assigned_admin_id uuid → profiles,     -- ⇄ Réassigner
         offer_id uuid → offers,
         current_stage_id uuid → stages,
         reward_amount numeric(10,2),           -- the green "1000 €"
         reward_status enum('pending','earned','invoiced','paid','cancelled'),
         status enum('active','archived_won','archived_lost'),
         deleted_at timestamptz,                -- SOFT delete only (§6.2)
         archived_at, created_at, updated_at)

stages(id, key, label, position, is_reward_trigger bool, is_terminal bool,
       banner_template text, comment_template text)
-- seed: a_contacter / rdv_programme / proposition_envoyee / devis_signe* / mission_terminee
--       * is_reward_trigger = true

recommendation_stage_events(id, recommendation_id, stage_id,
       completed_at, completed_by, comment text, reverted_at)
-- one row per stage reached ⇒ timeline + audit trail in one table.
-- "Remettre à zéro" sets reverted_at, it does NOT delete rows.

invoices(id uuid pk, recommendation_id, apporteur_id, issuer_id,
       number text unique not null,            -- sequential, gapless (§6.2)
       sequence_year int, sequence_index int,
       prestation_label text not null,
       intervened_on date, issued_on date, place text,
       amount numeric(10,2), currency char(3) default 'EUR',
       vat_regime enum('franchise_293b','standard'), vat_rate numeric, vat_amount numeric,
       payment_method text, tax_notice text,
       status enum('draft','awaiting_signatures','signed','paid','void'),
       pdf_path text, pdf_sha256 text,         -- immutable once signed
       created_at)
-- an invoice is NEVER updated after status='signed'; corrections create an avoir (credit note)

invoice_signatures(id, invoice_id, signer_id, role enum('apporteur','entreprise'),
       signed_at, signer_full_name, ip_address, user_agent, document_sha256,
       otp_verified bool)                       -- the evidential bundle (§6.1)

reminders(id, recommendation_id, created_by, due_at, label, channel enum('push','email'),
       status enum('scheduled','sent','done','cancelled'))   -- 🔔 Rappels

personal_notes(id, recommendation_id, author_id, body, updated_at)
documents(id, recommendation_id, type enum('invoice','quote','contract','other'),
       storage_path, filename, size, uploaded_by, created_at)
offers(id, title, description, category, supplier, energy_type,
       price_mode enum('quote','fixed'), price numeric, availability_label text,
       default_reward_amount, media_url, is_active, position)

tickets(id, opener_id, assignee_id, subject, status enum('open','pending','resolved','closed'),
       priority, thread_id, created_at, resolved_at)
threads(id, kind enum('direct','group','ticket'), recommendation_id, title, created_at)
thread_participants(thread_id, profile_id, last_read_at, pinned bool, archived bool)
messages(id, thread_id, sender_id, body, attachment_path, created_at)
commissions / payout_batches                      -- money
notifications(id, profile_id, type, payload jsonb, read_at, created_at)
audit_log(id, actor_id, entity, entity_id, action, before jsonb, after jsonb, created_at)
```

### 4.1 RLS — non-negotiable
```sql
-- an apporteur reads only his own recos
create policy reco_select on recommendations for select
  using (parrain_id = auth.uid() or is_admin(auth.uid()));

-- he may INSERT, never UPDATE stage / reward / status
create policy reco_insert on recommendations for insert
  with check (parrain_id = auth.uid());

-- invoices are readable by their apporteur and admins; writable only by admins,
-- and NOT UPDATABLE once signed
create policy invoice_no_update_after_sign on invoices for update
  using (status <> 'signed');
```
Stage advancement, reward amounts, invoice issuance and commission status must be
enforced **in the database**. Client-side checks are decoration.

---

## 5. Feature inventory

### 5.1 Shared (both roles, one iOS app)
Auth (signup w/ sponsor code, email verify, pending-approval state, biometric unlock,
forgot password) · Reco list (Actives/Archivées, search, refresh banner, pull-to-refresh) ·
Expandable card + 4-state stepper · Stage comment modal · Notes personnelles ·
Invoice viewer + signature · Catalogue · Chat · Profil · Notifications · Account deletion.

### 5.2 Apporteur-only
Create recommandation (filleul info + offer + **consent checkbox "j'ai informé le filleul"**) ·
Dashboard KPIs (recos actives, € en attente, € gagné, taux de conversion) ·
Commission history + annual statement · KYC docs + IBAN · Sign his side of the invoice.

### 5.3 Admin-only (in-app)
`Valider l'étape` + templated comment composer · Action sheet (Réassigner · Rappels ·
Remettre à zéro · Archiver · Supprimer) · Tap-to-call the filleul · Set/override reward ·
Generate the invoice · Sign as the company · Archive won/lost.

### 5.4 Admin-only (web back-office)
User approval, roles, suspension, KYC review · Catalogue CMS · Stage label / banner /
comment-template editor · Commission batches, SEPA & CSV export · Invoice archive &
10-year retention · Funnel analytics (conversion per stage / apporteur / offer, time-in-stage) ·
Chat console · Audit log viewer.

---

## 6. Legal & compliance — read before writing code

### 6.1 Electronic signature
The signature panel looks **home-made** (typed identity + a signed/not-signed checklist),
not Yousign/DocuSign. That is legal in France — a *simple* electronic signature is valid
(art. 1366-1367 Code civil) — but its **evidential value is weak** if the apporteur ever
disputes it. Two options:

| Option | Cost | Evidential value |
|---|---|---|
| Home-made simple signature **+ proper evidence bundle** (authenticated session, OTP by SMS, timestamp, IP, UA, SHA-256 of the exact PDF, immutable storage) | ~6 d | Acceptable for a B2B invoice between two consenting parties |
| **Yousign / Docaposte** (eIDAS advanced) | ~10-12 d + ~1-2 €/signature | Strong, reversal of the burden of proof |

Start home-made **but build the evidence bundle** — that's the `invoice_signatures` table above.
Without it, the signature is decorative.

### 6.2 Invoicing — the constraints that shape the schema
1. **Auto-facturation.** The document says *"Je soussigné : Johann Lefeuvre… Atteste"* but it
   is issued by Trinity Énergie's system. That is **self-billing on behalf of the apporteur**,
   which in France requires a **mandat de facturation signed in advance** by the apporteur.
   ⇒ Add that mandate to the onboarding flow. This is a real gap.
2. **Sequential, chronological, gapless numbering** (art. 242 nonies A, ann. II CGI).
   `1111` suggests this isn't respected. ⇒ numbering must be generated server-side in a
   transaction, per year, never client-side.
3. **Immutability + 10-year retention.** An issued invoice cannot be edited or deleted.
   ⇒ `Supprimer` on a reco that carries an issued invoice must be **blocked or soft-delete only**.
   Corrections go through an *avoir* (credit note). In the current app, `Supprimer` looks like
   a hard delete — that is a compliance bug, not a feature to clone.
4. **Mandatory mentions**: both parties' identity, address, SIRET, legal form, invoice date,
   due date, penalty rate, and the exact `Article 293 B du CGI` wording — which only applies
   **if the apporteur is under the franchise en base**. An apporteur above the threshold must
   be invoiced **with VAT**. ⇒ `profiles.vat_liable` drives the template.

### 6.3 RGPD
You store personal data on people who never signed up — the filleul. You need a legal basis,
a **consent checkbox in the create-reco form**, a retention policy, a deletion path, and a
DPA with Supabase. Most underestimated risk in this product category.

### 6.4 App Store
In-app account deletion (5.1.1 v) · privacy manifest · real-world-services payments are fine
(3.1.3) but word `Récompense` carefully · no financial-services claims you can't back.

### 6.5 Courtage en énergie
Depending on how the intermediation is framed, the activity and the remuneration may fall
under specific French rules (mandat, transparence de la rémunération). Confirm with the
business owner + a lawyer.

---

## 7. Where the time goes

Dev-days for **one experienced solo developer**. Learning SwiftUI while building ⇒ ×2 to ×2.5
on the iOS lines.

| # | Workstream | Days | % |
|---|---|---:|---:|
| 1 | Backend: schema, RLS, migrations, seeds, edge functions | 6 | 4% |
| 2 | Auth & onboarding (roles, sponsor code, approval state, **mandat de facturation**) | 7 | 5% |
| 3 | **SwiftUI design system** — 12 components incl. the 4-state stepper & the action sheet | 7 | 5% |
| 4 | **Reco module (iOS)** — list, search, filters, card, stepper, modals, notes, detail, create | 12 | 8% |
| 5 | **Admin in-app layer** — Valider l'étape + comment composer, action sheet, réassigner, reset, archive, soft-delete | 5 | 4% |
| 6 | **Invoice generator** — fields, server-side sequential numbering, VAT logic, PDF render, storage, immutability | 6 | 4% |
| 7 | **Dual e-signature** — flow, state machine, evidence bundle, OTP, hashing | 6 | 4% |
| 8 | Documents (viewer, signed URLs, share, PDFKit) | 4 | 3% |
| 9 | Rappels / reminders (scheduling, push, done state) | 3 | 2% |
| 10 | **Chat & Tickets** — realtime, 1:1 **+ groups**, pin/archive/unread filters, compose, attachments, push, **support ticket system** | 15 | 12% |
| 11 | **Catalogue** — list, chips, search, admin CRUD, **multi-step product wizard**, image upload | 7 | 5% |
| 12 | Accueil dashboard + stats | 4 | 3% |
| 13 | Profil, KYC, IBAN, commission history, settings, account deletion | 6 | 4% |
| 14 | Push notifications end-to-end + deep links + the "Actualiser" realtime banner | 5 | 4% |
| 15 | **Web back-office** (users/KYC, catalogue CMS, templates, commissions & exports, invoice archive, analytics, audit viewer) | 12 | 9% |
| 16 | Offline cache, error/empty/loading states, retries | 4 | 3% |
| 17 | i18n (FR/EN) + accessibility (Dynamic Type, VoiceOver, contrast) | 3 | 2% |
| 18 | Tests (unit, snapshot, **RLS policy tests**, invoice-numbering tests, critical UI flows) | 8 | 6% |
| 19 | CI/CD, TestFlight, App Store submission, privacy manifest | 4 | 3% |
| 20 | RGPD & legal pages (CGU, privacy, consent, retention, deletion) | 4 | 3% |
| | **Subtotal** | **128** | |
| | Buffer / QA / iteration (+20%) | **+26** | |
| | **TOTAL** | **≈ 154 dev-days** | |

**Calendar**
- Solo full-time (5 d/week): **~7.5 months**
- Solo student ~15 h/week: **~18-20 months** ⇒ take the MVP cut (§8)
- Two devs (1 iOS + 1 web/backend): **~4 months**
- Expo instead of SwiftUI, shared monorepo: **-30 to -35 days**

### The six things that will eat your schedule
1. **Invoicing + e-signature + their legal constraints (12% + legal review)** — this is the
   part that looks like "one screen" and is actually a compliance subsystem.
2. **The web back-office (9%)** — invisible in the screenshots, unavoidable in reality.
3. **Chat + tickets (12%)** — now the second-biggest line. Realtime is always ~2× the guess,
   and the ticket system is a second product. **Cut both from v1.**
4. **The 4-state stepper + expanding card (part of the 5% design system)** — the "exact clone" tax.
5. **Money correctness** — reward vs invoiced amount, earned vs invoiced vs paid. Bugs here
   aren't bugs, they're disputes with your partners.
6. **App Store review + RGPD (6%)** — first submission is always two rounds.

---

## 8. Phasing

| Phase | Weeks FT | Content | Goal |
|---|---|---|---|
| **P0 Foundations** | 1-2 | Supabase schema + RLS, auth + roles, Xcode project, design system skeleton, CI | A logged-in user sees an empty list |
| **P1 Vertical slice** | 3-5 | Reco list + card + 4-state stepper + comment modal, admin `Valider l'étape` with templated comment, push + refresh banner | **Core loop works end to end.** Demo-able |
| **P2 Complete the loop** | 6-9 | Create-reco form, catalogue, notes, action sheet, reminders, web back-office v1 (users + catalogue + templates) | Lead → signed quote |
| **P3 Money** | 10-13 | Invoice generator, sequential numbering, VAT logic, dual e-signature + evidence bundle, commissions, payouts, exports | **The business actually closes the loop** |
| **P4 Polish** | 14-16 | Dashboard, profil/KYC, empty/error states, i18n, a11y, analytics | Beta-ready |
| **P5 Chat & ship** | 17-19 | Realtime chat, hardening, legal pages, TestFlight, App Store | Live |

**MVP cut (~55 dev-days, ~11 weeks FT):** P0 + P1 + P2 + the invoice generator *without*
in-app signature (admin emails a PDF, apporteur signs on paper). No chat, no catalogue CMS
(hardcode offers), commissions tracked in-app but paid by bank transfer outside.
That already delivers the entire value proposition.

---

## 9. Open questions

**Blocking / architectural**
1. `1000 €` on the card vs `300.00 EUR` on the invoice — two different fields, or demo data?
2. Is the reward amount per-offer (from the catalogue) or set manually per reco?
3. Is there a **mandat de facturation** today, or is the company self-billing without one? (§6.2)
4. Are all apporteurs under the franchise en base (293B), or must the invoice handle VAT?
5. Are the 5 stages fixed forever, or admin-editable?
6. Does `Supprimer` hard-delete today? (compliance — §6.2)
7. iOS only, or Android within the year?

**Still need screenshots**
- The **apporteur/collaborator** side of the same screens (to confirm what's hidden from them)
- `Accueil`, `Catalogue`, `Chat`, `Profil`
- The **create-recommandation** form
- Auth / onboarding / sponsor-code flow
- `Archivées` tab, and a **refused/lost** reco (is there a red/failed stepper state?)
- `Notes personnelles` editor
- `Rappels` and `Réassigner` screens
- The `Devis signé` stage comment (missing template)
- The invoice **before** signature (unsigned state of the signature panel)

---

## 10. Next steps
1. Answer the 7 blocking questions → I lock the data model and re-cost.
2. Send batch #3 → I complete §2.
3. I then produce, in this order:
   a. the Supabase migration SQL + RLS policies + seed of the 5 stages and templates,
   b. the SwiftUI `DesignSystem` package (tokens + the 4-state stepper + card + modal + sheet),
   c. a clickable SwiftUI prototype of the `Recommandations` screen matching shots 1 and 5
      pixel-for-pixel — the cheapest way to validate the "exact clone" bar before committing
      to ~7 months of work.


---

## 11. "Why can't we build the whole thing in one weekend?"

Fair question, and part of the answer is: **a surprising amount of it, you can.** Here is the
honest split rather than a defensive one.

### 11.1 What a weekend genuinely buys you

20-25 focused hours with aggressive AI codegen ≈ **4-6 dev-days of output**, if the stack is
already familiar. A realistic weekend deliverable:

- Supabase project: schema, RLS first pass, auth, seed data (5 stages + templates + 3 offers)
- The `Recommandations` screen for real: list, search, `Actives`/`Archivées`, expandable card,
  the 4-state stepper, the comment modal
- `Valider l'étape` writing back to the database
- A Catalogue list

That is the **core loop, demo-able**, and it is genuinely the right first move — it validates
the "exact clone" quality bar before anyone commits months.

### 11.2 What a weekend cannot buy, hardest first

**1. Time that isn't yours.** App Store review is 24-72 h. External TestFlight builds are
reviewed too. Apple Developer enrolment is 24-48 h if you don't already have it. APNs
certificates and provisioning profiles are hours of portal friction. **None of this
compresses, at any budget.**

**2. Legal correctness.** No amount of codegen makes an invoice compliant: gapless sequential
numbering, 10-year immutable retention, the `mandat de facturation` required for self-billing,
VAT vs the 293B franchise, the e-signature evidence bundle. Done wrong, you have shipped a
liability, not a feature.

**3. Row Level Security.** One bad policy and every apporteur reads every other apporteur's
client list — names, phone numbers, deal values. Authorisation bugs are *silent*: nothing
crashes, the data just leaks. Writing and actually testing these policies is slow on purpose.

**4. Decisions nobody has made yet.** §9 lists 7 blocking questions, none answered.
`1000 €` vs `300 €` on the same reco is still unresolved. **You cannot code past an
unmade decision** — you can only guess, and then rewrite.

**5. Content.** Catalogue copy, the 5 comment templates, the tax-notice wording, CGU, privacy
policy. Writing is not coding and does not parallelise.

**6. The screens nobody has seen.** ~14 screenshots so far. A product like this has 40+.

### 11.3 The empirical argument

Each batch of screenshots has *raised* the estimate:

| After | Estimate | What newly appeared |
|---|---:|---|
| Batch 1 (4 shots) | 124 d | The core loop |
| Batch 2 (5 shots) | 143 d | Invoicing, dual e-signature, admin action sheet, reminders |
| Batch 3 (5 shots) | **154 d** | Catalogue admin CRUD + 5-step wizard, chat **groups**, pin/archive/unread, and a whole **ticketing system** |

Three batches, **+30 days**, and `Accueil`, `Profil`, the create-reco form, onboarding and the
entire apporteur-side view are still unseen. This is the normal shape of a clone job: the
screenshots show the happy path, and the happy path is roughly a third of the work.

### 11.4 Where the weekend maths actually lands

The 154 days assume **production**: legal, App Store, polish, error states, tests. A **rough
functional clone that looks right and demos well** is more like 30-40 days. So honestly:

| Goal | Verdict |
|---|---|
| Weekend prototype of the core loop | **Realistic — do it** |
| Weekend functional clone of everything | **~6-8× short** |
| Weekend production launch | Not a scheduling problem. Apple alone won't allow it |

### 11.5 What AI actually compresses

| Compresses a lot (2-4×) | Compresses a little | Doesn't compress |
|---|---|---|
| SwiftUI views, design system, CRUD screens, forms, schema, boilerplate, tests | On-device debugging, state edge cases, realtime sync, PDF layout | App Review, Apple enrolment, legal review, **your product decisions**, content writing, user testing |

Roughly **55% of the estimate sits in the first column** — which is *why the number is 154 and
not 400*. It already assumes heavy AI use. Halving that column again takes you to ~110 days.
Halving it a third time is not a thing that exists.

### 11.6 Recommendation

**Do the weekend.** Build the core-loop prototype in §11.1. It de-risks everything, it answers
the "can we really clone this?" question with code instead of opinion, and if it lands better
than predicted I will re-cost downward on the evidence. What should *not* happen is committing
to a launch date on the assumption that the weekend result is 80% of the product — it will be
closer to 4%, and the remaining 96% is where every energy-brokerage clone dies.
