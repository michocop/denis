# Android app — plan

Native Android (Kotlin + Jetpack Compose) in `android/`, a faithful port of the
iPhone app in `ios/`. Same Supabase project, same RPCs, same French copy, same
dark brand look. The iPhone app is not touched.

Stack: Kotlin 2.x, Compose (Material 3 underneath, restyled to the brand),
OkHttp + kotlinx.serialization for a hand-written Supabase client that mirrors
`ios/Sources/EnergyCourtage/Core/SupabaseClient.swift` (same endpoints,
headers, single-flight token refresh, French error messages), coroutines/Flow
for state, EncryptedSharedPreferences for the refresh token. minSdk 26,
targetSdk 36, package `com.trinityenergie.energycourtage`.

Config: the Supabase URL and anon key are read at build time from
`ios/Config.xcconfig` (one source for both apps). Without it the app starts in
demo mode, like iOS.

Toolchain lives in `.devtools/` (git-ignored): JDK 17, Android SDK, Gradle.
`source scripts/android_env.sh` puts them on PATH.

## Status (27 Oct 2026)

Lots 1–4 are built, merged on `feat/android`, and walked through on the
emulator in demo mode, as apporteur and as company: sign-in, onboarding and
contract by SMS, Home, recommendations (list, stages, detail, create with the
duplicate check, notes, reminders, a document added from a file, admin
actions), invoices (both signatures, the PDF), chat, notifications and their
routing, profile, members and invitations, payouts, commissions. 128 unit tests.

27 Oct 2026, on the release build (R8, upload key) that trinity-energie.fr/app
serves, version 1.0.1:
- a "Relance" fires on time with the app in the background, and tapping it
  opens the recommendation without rebuilding the app (it used to be torn down
  and lose the demo, or lock a signed-in user again);
- the notification permission is asked when a reminder is scheduled, as on
  iOS (it used to be asked only once push was configured, so reminders never
  showed on Android 13+);
- the photo picker adds a compressed photo; files and the contract PDF open;
- asking for a code from an uninvited address reaches production and shows
  the right French message;
- 1.0.1 installs over 1.0 from the website (same key, versionCode 2);
- the whole app is French whatever the phone's language (date and time
  pickers included).
Not tried yet: the document scanner (the emulator has no Google account, so
Play services will not download the module; the app now fetches it as soon as
Documents shows), and a signed-in session against production.

Still open:
- Never yet signed in against the real project with a real account.
- Push (lot 5): the code is in, it needs a Firebase project (see
  `android/firebase.properties.example`, then `scripts/link_fcm.sh`).
- Google Play: a developer account, a release signing key, then internal
  testing; put the install link in `ANDROID_INSTALL_URL` (ui/admin/AdminLogic.kt)
  and in the invitation email (supabase/functions/auth-email, INSTALL_URL).

Run it: `source scripts/android_env.sh`, `cd android && ./gradlew :app:installDebug`
(an emulator: `.devtools/avd`, `emulator -avd trinity -no-window`).

## Lots

1. **Foundation** — project, theme (colours, Sora/Manrope, card surface,
   buttons), Supabase client, session store, sign-in by emailed code, the
   account phases (pending, suspended, complete invite), the four tabs, Home.
2. **Recommendations** — list (actives/archivées, search, paging), card with
   stage stepper, detail, create (duplicate check, consent), notes, reminders
   (local alarm), admin actions.
3. **Signing** — invoice screen, SMS code flow, phone verification, PDF view
   and share; legal documents gate; apporteur onboarding and contract.
4. **The rest** — chat (threads, messages, tickets), notifications list,
   profile (billing, export, delete account), admin members/invite/payables,
   commissions, lead documents (photos, files, ML Kit scanner).
5. **Distribution** — push through FCM (server: `send-push` learns FCM,
   `device_tokens.platform = 'android'`), Play Console internal testing,
   install link in the invite email and share message.

## Needs from Michel

- Google Play Console developer account (25 $ one-time). As an organisation it
  asks for the same D-U-N-S number as Apple.
- A Firebase project for push (free), for lot 5.
