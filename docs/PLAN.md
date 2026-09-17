# Energy Courtage — Apporteur d'Affaires Platform
## Clone analysis + full build plan (v1 — based on screenshot batch #1)

> Status: **living document**. This version is built from the 4 screenshots of the
> `Recommandations` tab (list + 3 comment modals). Sections marked `❓ TO CONFIRM`
> are assumptions I will replace as the remaining screenshots arrive.

---

## 1. What the product actually is

An **energy brokerage (courtage en énergie) referral platform**. Two populations:

| Role | Who | What they do |
|---|---|---|
| **Apporteur / Collaborateur** | Independent business introducer | Submits leads ("recommandations"), follows their progress through a pipeline, chats with the broker, browses the offer catalogue, tracks and collects commissions |
| **Admin / Courtier** | The brokerage's internal staff | Receives leads, advances the pipeline stage by stage, writes a comment at each stage, uploads the signed contract, validates and pays the reward, manages the catalogue, users and chat |

The whole product is essentially **one shared object — the `recommandation` — seen from two sides**.
The collaborator sees a *read-only, beautifully presented* timeline. The admin sees an
*editable* pipeline. Nail that object and 70% of the app exists.

### The money model (inferred)
- A recommandation carries a **reward amount** (`1000 €`, shown in green).
- The reward **unlocks at a specific stage** — the `Récompense` 🎁 badge sits on
  **"Devis signé"**, not on "Mission terminée". So: quote signed ⇒ commission earned.
  Payment probably happens after "Mission terminée". `❓ TO CONFIRM`
- Amount is likely **per-offer** (from the Catalogue) or manually set by the admin. `❓ TO CONFIRM`

---

## 2. Screen-by-screen spec extracted from batch #1

### 2.1 `Recommandations` list (screenshot 1)

```
┌──────────────────────────────────────────┐
│ Recommandations              (large title)│
│ ┌──────────┬──────────┐                   │
│ │ Actives  │ Archivées│  custom segmented │
│ └──────────┴──────────┘                   │
│ 🔍 Rechercher...                          │
│ ┌──────────────────────────────────────┐  │
│ │ Thomas Dubois            1000 €   ⌃  │  │  ← card, expandable
│ │ Recommandé par Johann Lefeuvre        │  │
│ │ Aujourd'hui à 14:57                   │  │
│ │ ┌──────────────────────────────────┐  │  │
│ │ │ Contrat signé. Disponible dans   │  │  │  ← green status banner
│ │ │ l'onglet Documents               │  │  │
│ │ └──────────────────────────────────┘  │  │
│ │ ✅ À contacter                    💬  │  │
│ │ │                                      │  │
│ │ ✅ RDV programmé                  💬  │  │  ← vertical stepper
│ │ │                                      │  │
│ │ ✅ Proposition envoyée            💬  │  │
│ │ │                                      │  │
│ │ ✅ Devis signé      🎁 Récompense 💬  │  │
│ │ │                                      │  │
│ │ ✅ Mission terminée               💬  │  │
│ │ [ 📄 Notes personnelles ]             │  │
│ │ [ 📄 Voir le contrat ]                │  │
│ │ [ Voir plus ]                         │  │
│ └──────────────────────────────────────┘  │
│ Accueil  Reco  Catalogue  Chat  Profil    │  ← 5-tab bar
└──────────────────────────────────────────┘
```

**Behaviours to replicate**
1. `Actives` / `Archivées` segmented filter (archived = won/lost/abandoned).
2. Client-side (or server-side) text search across client name + referrer name.
3. Card collapse/expand via the chevron — **animated height change**, chevron rotates.
4. Status banner appears only when a terminal/notable state is reached; its text is
   **state-derived copy**, not free text ("Contrat signé. Disponible dans l'onglet Documents").
5. Stepper: 5 fixed stages, green filled + white check when done, connector line green
   between two completed steps. `❓ TO CONFIRM` the pending/current/refused visual states —
   I need a screenshot of a reco that is *not* fully complete.
6. `Récompense` badge pinned to the reward-triggering stage.
7. Comment bubble per stage → opens the modal (2.2). Bubble is presumably **hidden or
   greyed when no comment exists** — here all 5 have one. `❓ TO CONFIRM`
8. `Notes personnelles` → the collaborator's own private notes (not visible to admin? `❓`).
9. `Voir le contrat` → only when a contract document is attached.
10. `Voir plus` → full detail sheet/page (client contact details, offer, history…). `❓ TO CONFIRM`

### 2.2 Stage comment modal (screenshots 2, 3, 4)

Centered dialog, dimmed backdrop, not a bottom sheet:
- Circular light-blue avatar with 💬 glyph
- Title on two lines: `Commentaire pour l'étape` / `"À contacter"`
- Label `Message`
- Read-only grey text block
- Primary blue `Fermer` button, right aligned

**Key insight — the comments are templated.** Look at them:

| Stage | Comment |
|---|---|
| À contacter | « Merci pour la mise en relation. Nous avons bien reçu les coordonnées de **Thomas Dubois**. Prochain point après le 1er échange. » |
| RDV programmé | « J'ai contacté **Thomas Dubois**. Le rendez-vous est planifié. Je vous tiens informé(e) de la suite. » |
| Proposition envoyée | « J'ai transmis à **Thomas Dubois** la proposition. Retour attendu très prochainement. » |

Same voice, same structure, client name injected. So the admin side has a
**comment template per stage with `{client_name}` interpolation**, pre-filled and editable.
That is a real feature, not a coincidence — build it (saves the admin enormous time and
keeps the tone consistent).

### 2.3 Tab bar
`Accueil` · `Reco` (center, with a "+document" glyph ⇒ probably also the *create* entry point)
· `Catalogue` · `Chat` · `Profil`. Active tint = brand blue.

### 2.4 Design tokens (sampled from the screenshots — refine against the real source)

```swift
// Colors
brandBlue      #2196D3   // tint, links, primary buttons, active tab   ❓ exact hex
successGreen   #22C55E   // stepper circles, connector lines
successText    #16A34A   // "1000 €", banner text
successBg      #DCFCE7   // status banner background
rewardBg       #FEF3C7   // Récompense pill
rewardText     #B45309
textPrimary    #111827
textSecondary  #9CA3AF
surface        #FFFFFF   // cards, modal
trackGrey      #F1F2F4   // segmented control track, message block
hairline       #E5E7EB

// Radii
card 16-20 · searchField 14 · segmented 12(inner)/14(outer) · button 12 · modal 24 · pill full

// Type — geometric sans, looks like Poppins / Figtree family  ❓ CONFIRM the real font
title       28-30 semibold
cardTitle   22 semibold
body        17 regular
secondary   16 regular  textSecondary
```

Spacing rhythm looks like a 4/8 pt grid with 16 pt screen gutters and 20 pt card padding.

---

## 3. Recommended tech stack

You asked for native Swift "or whatever is best". Here is the honest answer.

### 3.1 Decision

| Part | Recommendation | Why |
|---|---|---|
| **Collaborator app** | **SwiftUI, iOS 17+** | This is the app 95% of your users touch daily. The UI in your screenshots is animation-heavy (expanding cards, steppers, modals) — SwiftUI does that beautifully and the result feels native. |
| **Admin app** | **Next.js 15 web back-office** (React + TypeScript + Tailwind + shadcn/ui) | ⚠️ Do **not** build the admin as a second iOS app. Admin work = data entry, tables, bulk actions, document upload, exports. That is miserable on a phone and doubles your iOS work. A web back-office is ~40% faster to build, works on desktop where the staff actually sits, and ships without App Review. Make it responsive so it's usable on a phone in the field. |
| **Backend** | **Supabase** (Postgres + Auth + Row Level Security + Storage + Realtime + Edge Functions) | Your data is deeply relational (users → recos → stages → comments → documents → commissions). RLS lets you enforce "an apporteur only sees his own recos" *in the database*, which is the single most important security property of this product. Storage handles contracts, Realtime handles chat, Edge Functions handle push + business rules. |
| **Push** | APNs via Supabase Edge Function (or Firebase Cloud Messaging if you add Android later) | |
| **Analytics/crash** | TelemetryDeck or PostHog + Sentry | RGPD-friendly options |

### 3.2 The alternative you should consider seriously

**If Android is needed within 6 months → use Expo (React Native) + Next.js admin in one TypeScript monorepo.**
You share types, validation schemas, API client and business rules between the three surfaces.
Realistic saving: **25-35% of total time**, at the cost of a slightly less "perfect" feel on
the expanding-card animations.

**Decision rule:** iOS-only for the first 12 months ⇒ SwiftUI. Android on the roadmap ⇒ Expo.
Given you're a student building this solo, I'd genuinely consider Expo. But the plan below
assumes **SwiftUI + Next.js + Supabase**, since that's what you asked for.

### 3.3 iOS architecture

```
EnergyApp/
├── App/                 entry point, routing, deep links, environment
├── DesignSystem/        tokens, Card, Stepper, StatusBanner, RewardBadge,
│                        SegmentedControl, SearchField, AlertModal, TabBar
├── Core/
│   ├── Networking/      Supabase client wrapper, typed endpoints, error mapping
│   ├── Auth/            session, keychain, refresh, role gating
│   ├── Persistence/     SwiftData cache for offline list reads
│   └── Push/            APNs registration, deep-link routing
├── Features/
│   ├── Home/            dashboard, KPIs
│   ├── Recommendations/ list, filters, detail, create, stepper, comments, notes
│   ├── Catalogue/       offers list + detail
│   ├── Chat/            threads, realtime messages, attachments
│   └── Profile/         profile, KYC, IBAN, commissions, settings, account deletion
└── Tests/               unit + snapshot + UI
```

Patterns: MVVM with `@Observable` (Swift 5.9+), `async/await` everywhere, protocol-based
repositories so every view model is testable against a fake, one `AppRouter` for deep links.

---

## 4. Data model (Postgres)

```sql
-- people
profiles(id uuid pk → auth.users, role enum('collaborator','admin','manager'),
         first_name, last_name, phone, avatar_url, status enum('pending','active','suspended'),
         sponsor_id uuid → profiles,          -- multi-level referral (see §4.1)
         iban_encrypted, kyc_status, created_at)

-- the core object
recommendations(id uuid pk,
         client_first_name, client_last_name, client_phone, client_email,
         company_name, siret, client_address,
         referrer_id uuid → profiles,          -- "Recommandé par Johann Lefeuvre"
         assigned_admin_id uuid → profiles,
         offer_id uuid → offers,
         current_stage_id uuid → stages,
         reward_amount numeric(10,2),
         reward_status enum('pending','earned','paid','cancelled'),
         status enum('active','archived_won','archived_lost'),
         archived_at, created_at, updated_at)

-- configurable pipeline (do NOT hardcode the 5 stages)
stages(id, key, label, position, is_reward_trigger bool, is_terminal bool,
       banner_template text, comment_template text)
-- seed: à_contacter / rdv_programmé / proposition_envoyée / devis_signé* / mission_terminée
--       * is_reward_trigger = true

recommendation_stage_events(id, recommendation_id, stage_id,
         completed_at, completed_by uuid → profiles, comment text)
-- one row per stage reached ⇒ gives you the timeline AND the audit trail for free

personal_notes(id, recommendation_id, author_id, body, updated_at)   -- private to the author
documents(id, recommendation_id, type enum('contract','quote','other'),
         storage_path, filename, size, uploaded_by, created_at)

-- catalogue
offers(id, title, description, category, supplier, energy_type enum('elec','gaz','both'),
       default_reward_amount, media_url, is_active, position)

-- chat
threads(id, recommendation_id nullable, created_at)
thread_participants(thread_id, profile_id, last_read_at)
messages(id, thread_id, sender_id, body, attachment_path, created_at)

-- money
commissions(id, recommendation_id, profile_id, amount, status, earned_at, paid_at,
            payout_batch_id)
payout_batches(id, period, total, executed_at, executed_by)

notifications(id, profile_id, type, payload jsonb, read_at, created_at)
audit_log(id, actor_id, entity, entity_id, action, before jsonb, after jsonb, created_at)
```

### 4.1 The open question that changes the data model

Screenshot 1 says **"Recommandé par Johann Lefeuvre"** on the collaborator's own screen.
Two possible readings:

- **(A)** This screen belongs to an **admin/manager**, who naturally needs to see the referrer.
- **(B)** The platform is **multi-level**: a collaborator recruits sub-collaborators (`sponsor_id`),
  and sees the recos submitted by his downline — and possibly earns an override commission on them.

(B) is common in apporteur d'affaires networks and would significantly expand the scope
(network tree, override commission rules, network stats screen). **This is the #1 thing I need
you to clarify** — it can swing the estimate by 2-3 weeks.

### 4.2 Security — RLS policies (non-negotiable)

```sql
-- a collaborator reads only his own recos (+ his downline's if multi-level)
create policy reco_select on recommendations for select
  using (referrer_id = auth.uid() or is_admin(auth.uid()));

-- a collaborator may INSERT but never UPDATE stage/reward fields
create policy reco_insert on recommendations for insert
  with check (referrer_id = auth.uid());
```
Stage advancement, reward amounts and commission status must be writable **only by admins**,
enforced in the DB, not in the app. Client-side checks are decoration.

---

## 5. Feature inventory

### 5.1 Collaborator iOS app

| Tab | Features |
|---|---|
| **Accueil** | KPIs (recos actives, €︎ en attente, €︎ gagné, taux de conversion), recent activity feed, quick "Nouvelle recommandation" CTA, unread chat/notification badges |
| **Reco** | List (Actives/Archivées, search, sort), expandable card with stepper, stage comment modal, personal notes editor, contract viewer/download, "Voir plus" detail, **create form** (client info + offer + consent checkbox), pull-to-refresh, empty/loading/error states, push deep-links into a reco |
| **Catalogue** | Offers grid/list, category filter, offer detail (description, reward amount, supporting docs), "Recommander cette offre" → pre-fills the create form |
| **Chat** | Thread list, realtime 1:1 with the broker, per-reco threads, attachments, unread badges, push |
| **Profil** | Personal info, avatar, KYC document upload, IBAN, commission history + statement export, notification preferences, CGU/privacy, **account deletion** (mandatory for App Store), logout |
| **Auth** | Signup (probably invite/sponsor-code gated), login, biometric unlock, forgot password, email verification, pending-approval state |

### 5.2 Admin web back-office

| Module | Features |
|---|---|
| **Pipeline** | Table + kanban of all recos, filters (stage, apporteur, date, amount), bulk actions, assignment |
| **Reco detail** | Advance stage → **auto-filled templated comment** (editable) → notifies the apporteur, upload contract/quote, set/override reward, archive won/lost, full audit trail |
| **Users** | Approve signups, roles, suspend, KYC review, view an apporteur's performance |
| **Catalogue CMS** | CRUD offers, categories, default reward amounts, ordering, publish/unpublish |
| **Commissions** | Earned/paid states, payout batches, CSV/SEPA export, monthly statements |
| **Chat console** | Inbox across all apporteurs, assignment, canned replies |
| **Templates** | Edit stage labels, banner copy and comment templates without a deploy |
| **Analytics** | Funnel conversion per stage, per apporteur, per offer; time-in-stage |

---

## 6. Where the time goes

Estimates are **dev-days for one experienced solo developer**. If you are learning SwiftUI
while building, multiply the iOS lines by **~2 to 2.5**.

| # | Workstream | Days | % | Why it costs what it costs |
|---|---|---:|---:|---|
| 1 | Backend: schema, RLS, migrations, seeds, edge functions | 6 | 6% | RLS policies + testing them is the slow part, not the tables |
| 2 | Auth & onboarding (both apps, roles, invite codes, approval state) | 6 | 6% | Every edge case (unverified, pending, suspended) needs a screen |
| 3 | **SwiftUI design system** (tokens + 12 components to match the screenshots pixel-for-pixel) | 7 | 7% | This is the "clone it exactly" tax. The expanding card + animated stepper alone is 2 days |
| 4 | **Reco module (iOS)** — list, search, filters, card, stepper, modals, notes, detail, create form | 12 | 12% | The heart of the app. Also the most state: 5 stages × 4 visual states × empty/error |
| 5 | Documents & contracts (upload, signed URLs, PDFKit viewer, share sheet) | 4 | 4% | Cheap — unless you add e-signature (see risks) |
| 6 | Chat (realtime, threads, attachments, unread, push) | 9 | 9% | Realtime + read state + ordering + offline resend is always 2× what people guess |
| 7 | Catalogue (iOS) | 4 | 4% | |
| 8 | Accueil dashboard + stats | 4 | 4% | |
| 9 | Profil, KYC, IBAN, commission history, settings, account deletion | 6 | 6% | |
| 10 | Push notifications end-to-end + deep links | 4 | 4% | Certificates, tokens, routing, testing on device |
| 11 | **Admin web back-office (all modules)** | 20 | 20% | ⚠️ The single biggest line, and the one everyone forgets. Tables, forms, uploads, exports, permissions |
| 12 | Offline cache, error/empty/loading states, retries | 4 | 4% | The difference between a demo and a product |
| 13 | i18n (FR/EN) + accessibility (Dynamic Type, VoiceOver, contrast) | 3 | 3% | Cheap now, brutal to retrofit |
| 14 | Tests (unit, snapshot, RLS policy tests, critical UI flows) | 7 | 7% | Money logic must be tested |
| 15 | CI/CD, TestFlight, App Store submission, privacy manifest | 4 | 4% | First submission is always 2 rounds |
| 16 | RGPD & legal (CGU, privacy policy, consent on lead data, deletion flow) | 3 | 3% | You are storing **third-party personal data** (the prospect!) — see risks |
| | **Subtotal** | **103** | | |
| | Buffer / QA / iteration (+20%) | **+21** | | Non-negotiable |
| | **TOTAL** | **~124 dev-days** | | |

**Calendar translation**
- Solo full-time (5 d/week): **~6 months**
- Solo student, ~15 h/week: **~14-16 months** ⇒ *strongly* consider cutting scope (see §7)
- Two devs (1 iOS + 1 web/backend): **~3.5 months**
- With Expo instead of SwiftUI + shared monorepo: subtract ~25-30 days

### The 5 things that will eat your schedule
1. **The admin back-office (20%)** — invisible in the screenshots, unavoidable in reality.
2. **Chat (9%)** — realtime is deceptively expensive. Consider shipping v1 with a simple
   "contact support" form and adding chat in v2. Saves ~9 days.
3. **Pixel-perfect design system (7%)** — the cost of "exactly clone this".
4. **Money correctness** — commissions, payout states, audit trail. Bugs here are not bugs,
   they are disputes with your partners. Test it hard.
5. **App Store review + RGPD** — see §8.

---

## 7. Phasing — how I'd actually ship this

| Phase | Weeks (full-time) | Content | Goal |
|---|---|---|---|
| **P0 — Foundations** | 1-2 | Supabase schema + RLS, auth, Xcode project, design system skeleton, CI | A logged-in user sees an empty list |
| **P1 — Vertical slice** | 3-5 | Reco list + card + stepper + comment modal, admin can advance a stage, push notification lands | **The core loop works end to end.** Demo-able |
| **P2 — Complete the loop** | 6-9 | Create-reco form, catalogue, documents/contract, notes, admin pipeline + templates + users | An apporteur can go from lead to signed contract |
| **P3 — Money & polish** | 10-12 | Commissions, payouts, dashboard, profile/KYC, empty/error states, i18n, a11y | Beta-ready |
| **P4 — Chat & scale** | 13-15 | Realtime chat, analytics, exports, notification center | Feature-complete |
| **P5 — Ship** | 16-17 | Hardening, TestFlight round, legal pages, App Store submission | Live |

**MVP cut (if you need something in 6-8 weeks):** P0 + P1 + P2 only, no chat, no catalogue CMS
(hardcode the offers), commissions displayed but paid manually outside the app. That is
~45 dev-days and it already delivers the actual value.

---

## 8. Risks & constraints (read this before writing code)

1. **RGPD — you store personal data about people who never signed up** (the prospect,
   Thomas Dubois). You need: a legal basis, a consent checkbox in the create-reco form
   ("j'ai informé le prospect"), a retention policy, and a deletion path. This is the most
   underestimated legal risk of any apporteur d'affaires app. Budget a lawyer review.
2. **Courtage en énergie regulation** — depending on how the intermediation is framed,
   the apporteur's activity and the commission may fall under specific French rules
   (mandat, transparence de la rémunération). Confirm with the business owner.
3. **Apple App Review** — a referral app that pays real-world commissions is fine
   (guideline 3.1.3, real-world services), but: you need **in-app account deletion**
   (5.1.1(v)), a privacy manifest, and careful wording so "Récompense" doesn't read as a
   gambling/loot mechanic. Also: no sign-up fee flow outside IAP.
4. **IBAN storage** — encrypt at rest, never log it, restrict it with RLS to the owner +
   the finance admin role. Or offload payouts to a provider (Stripe Connect / Qonto API).
5. **E-signature** — if "Devis signé" must happen *inside* the app, you need Yousign or
   DocuSign: add **8-12 days** and a recurring cost. If signature happens outside and the
   admin just uploads the PDF (which is what the screenshot suggests), you're fine.
6. **Font licensing** — if the original uses a commercial font (Gilroy, etc.), buy the app
   licence or substitute a metrically-similar free one (Poppins, Figtree).

---

## 9. What I still need from you

**Screenshots (the ones you're about to send):** Accueil, Catalogue, Chat, Profil, the
create-recommendation flow, the auth/onboarding screens, the "Voir plus" detail view, and —
important — **a recommendation that is NOT complete**, so I can see the pending / current /
refused states of the stepper, and a card in the `Archivées` tab.

**Questions that change the architecture:**
1. Is the network **multi-level** (a collaborator recruits sub-collaborators and earns on
   them), or flat? (§4.1) — *biggest single unknown*
2. Is the screenshot the collaborator view or an admin/manager view?
3. Is the reward amount per-offer, or set manually per reco?
4. Does the contract get **signed in-app** (e-signature) or uploaded by the admin?
5. Are the 5 pipeline stages fixed forever, or should the admin be able to edit them?
6. Is the admin side an app you have screenshots of, or do I design it from scratch?
7. iOS only, or Android too within the year?
8. Are commissions paid through the app, or just tracked and paid by bank transfer?

---

## 10. Immediate next steps

1. You send batch #2 of screenshots → I extend §2 with a full screen inventory.
2. You answer the 8 questions in §9 → I lock the data model and re-cost the estimate.
3. I produce: the Supabase migration SQL, the SwiftUI design-system package, and a
   clickable SwiftUI prototype of the `Recommandations` screen matching screenshot #1
   pixel-for-pixel — that is the best way to validate the "exact clone" bar before
   committing to 4 months of work.
