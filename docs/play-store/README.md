# Google Play: everything to paste

The signed bundle to upload: `android/app/build/outputs/bundle/release/app-release.aab`
(rebuild with `cd android && ./gradlew :app:bundleRelease`; the upload key is
`android/signing/upload.jks`, its password in the Keychain item
`trinity-android-upload-key`. Keep a copy of both somewhere safe.)

Package: `com.trinityenergie.energycourtage` · version 1.0 (code 1) · targets Android 16 (API 36), runs from Android 8.

---

## 1. App details

| Field | Value |
|---|---|
| App name | Trinity Énergie |
| Default language | Français (France) – fr-FR |
| App or game | App |
| Free or paid | Free |
| Category | Business (Entreprise) |
| Contact email | pierrelouis@trinity-energie.fr |
| Website | https://trinity-energie.fr |
| Privacy policy URL | see §6 |

**Short description** (80 max):

> Recommandez des professionnels, suivez vos dossiers et signez vos factures.

**Full description** (4000 max):

> Trinity Énergie est l'espace des apporteurs d'affaires du courtier en électricité et gaz Trinity Énergie.
>
> Vous connaissez un professionnel qui paie trop cher son énergie ? Recommandez-le en quelques secondes, suivez son dossier étape par étape, et recevez votre commission dès que le contrat est signé.
>
> • Recommander : nom, téléphone, et si vous l'avez, sa facture d'énergie — photographiée, scannée ou jointe en PDF.
> • Suivre : chaque recommandation avance par étapes (contact, rendez-vous, proposition, devis signé, mission terminée), avec les commentaires de l'équipe.
> • Être payé : votre facture d'apport d'affaires est établie pour vous (autofacturation), vous la signez dans l'application avec un code reçu par SMS, et vous la retrouvez en PDF.
> • Échanger : une messagerie directe avec l'équipe, et des tickets pour vos questions.
> • Rester informé : notifications quand un dossier avance, qu'une facture est à signer ou qu'un paiement part.
>
> Connexion sans mot de passe : saisissez votre adresse, vous recevez un code à six chiffres par e-mail.
>
> L'accès est réservé aux apporteurs invités par Trinity Énergie. Pour découvrir l'application sans compte, touchez « Découvrir l'application (démo) » sur l'écran de connexion : toutes les données y sont fictives.

**Graphics** (all in this folder):
- App icon: `icon-512.png`
- Feature graphic: `feature-graphic-1024x500.png`
- Phone screenshots, in this order: `screenshots/01-signin.png` … `06-members.png` (1080×2160)

---

## 2. App access (Policy → App content → App access)

Choose **"All or some functionality is restricted"**, add one instruction:

> Name: Mode démo
> Instructions: L'application est réservée aux apporteurs invités, qui se connectent avec un code envoyé à leur adresse e-mail. Pour l'examiner sans compte : sur l'écran de connexion, touchez « Découvrir l'application (démo) », puis « Vue apporteur » (l'apporteur d'affaires) ou « Vue entreprise » (l'administrateur). Toutes les fonctions sont disponibles avec des données fictives. Quand un code SMS est demandé, saisissez 123456.

## 3. Ads, audience, content

| Form | Answer |
|---|---|
| Ads | No, the app has no ads |
| Target audience | 18 and over only |
| Content rating (IARC) | Category "Utility, productivity, communication or other". Answer **No** to every question (violence, sexuality, language, drugs, gambling…) except: **users can interact / exchange messages: Yes** (the in-app chat with the company). **Shares user location: No.** **Digital purchases: No.** Expected rating: PEGI 3 / Everyone |
| News app | No |
| COVID-19 app | No |
| Government app | No |
| Financial features | None of the listed features (the app does not move money; payouts are bank transfers made outside it) |
| Health | No |
| Data safety | see §4 |

## 4. Data safety

**Does your app collect or share any of the required user data types?** Yes.
**Is all collected data encrypted in transit?** Yes (HTTPS only).
**Do you provide a way for users to request that their data is deleted?** Yes: in the app (Profil → Supprimer mon compte) and at the URL in §6.

Data is **not shared** with third parties: Supabase (hosting, Paris), Brevo (e-mails and SMS) and Google Firebase (notifications) are service providers processing it on Trinity Énergie's behalf, which Play does not count as sharing.

| Data type | Collected | Required? | Purposes |
|---|---|---|---|
| Personal info → Name | Yes | Required | App functionality, Account management |
| Personal info → Email address | Yes | Required | App functionality, Account management |
| Personal info → Phone number | Yes | Required for signing | App functionality, Account management (SMS signing codes) |
| Personal info → Address | Yes | Required for invoicing | App functionality |
| Personal info → Other info (SIRET, legal form, the recommended person's contact details) | Yes | Required | App functionality |
| Financial info → Other financial info (commission amounts, invoices) | Yes | Required | App functionality |
| Messages → Other in-app messages | Yes | Optional | App functionality |
| Photos and videos → Photos | Yes | Optional (photos of energy bills) | App functionality |
| Files and docs | Yes | Optional (energy bills, PDFs) | App functionality |
| Device or other IDs | Yes | Optional (notification token) | App functionality (push notifications) |

Not collected: location, contacts, calendar, browsing, app activity/analytics, crash logs, audio, health, payment card or bank account data.
For each collected type: **processed ephemerally? No**, **collected, not shared**.

## 5. Release

1. Testing → **Closed testing** → create track "Apporteurs" → add testers (email list of their Google accounts) → upload `app-release.aab` → release notes:
   > Première version Android de l'espace apporteur Trinity Énergie.
2. Accept **Play App Signing** when asked (Google keeps the app key; ours is the upload key).
3. The testers' opt-in link is `https://play.google.com/apps/testing/com.trinityenergie.energycourtage`.
4. Production (once allowed): Publishing overview → send for review. The store link will be
   `https://play.google.com/store/apps/details?id=com.trinityenergie.energycourtage`.

## 6. Privacy policy and account deletion URLs

Play requires two public web pages: the privacy policy, and how to delete an account.
They are written in `site/` (`confidentialite.html`, `suppression-compte.html`), from the published policy.
They still need a public address — see the question in the last message.
