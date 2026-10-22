# Android app — plan

Native Android (Kotlin + Jetpack Compose) in `android/`, a faithful port of the
iPhone app in `ios/`. Same Supabase project, same RPCs, same French copy, same
dark brand look. The iPhone app is not touched.

Stack: Kotlin 2.x, Compose (Material 3 underneath, restyled to the brand),
OkHttp + kotlinx.serialization for a hand-written Supabase client that mirrors
`ios/Sources/EnergyCourtage/Core/SupabaseClient.swift` (same endpoints,
headers, single-flight token refresh, French error messages), coroutines/Flow
for state, EncryptedSharedPreferences for the refresh token. minSdk 26,
targetSdk 35, package `com.trinityenergie.energycourtage`.

Config: the Supabase URL and anon key are read at build time from
`ios/Config.xcconfig` (one source for both apps). Without it the app starts in
demo mode, like iOS.

Toolchain lives in `.devtools/` (git-ignored): JDK 17, Android SDK, Gradle.
`source scripts/android_env.sh` puts them on PATH.

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
