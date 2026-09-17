# EnergyCourtage — iOS

SwiftUI package for the collaborator/admin app. One binary serves both roles:
the list, card, stepper and dialogs are shared, and `UserRole` gates the
admin-only affordances (`Valider l'étape`, and later the action sheet and the
company signature panel). Authority is enforced in Postgres — see
`supabase/migrations/…_rls.sql`. The role check here is presentation only.

## Status

| | |
|---|---|
| Built | All five tabs (Accueil, Reco, Catalogue, Chat, Profil), sign-in, create-recommendation form with the RGPD consent gate, the admin action sheet, the invoice viewer with dual signature, the product wizard, the design system, Supabase repositories for every screen, and unit tests |
| Not built yet | Push notifications, realtime subscriptions, the thread detail view, offline cache, reminders UI, PDF rendering |

**Not yet compiled.** This package was written on Linux, where no Swift
toolchain is available, so it has had a careful read-through but not a build.
Expect to fix a few small things on first `swift build` / Xcode open.

## Run it

```bash
# runnable app (Simulator)
brew install xcodegen && cd ios && xcodegen generate
open EnergyCourtage.xcodeproj     # set SUPABASE_URL / SUPABASE_ANON_KEY

# previews and tests only, no app target needed
open ios/Package.swift
swift test
```

A Swift package previews in Xcode but cannot run in the Simulator on its own;
`project.yml` generates the app target that hosts it. Without XcodeGen: create
an iOS App project by hand and add `ios/` as a local package dependency.

Four previews reproduce the reference screenshots: the completed Thomas Dubois
card, the same card mid-pipeline (completed / current / pending together), the
stage comment dialog, and the full screen in both roles.

## Layout

```
Sources/EnergyCourtage/
  DesignSystem/   Theme.swift (all tokens), StageStepper.swift, Controls.swift
  Models/         Domain.swift — Stage, StageEvent, Recommendation, UserRole
  Core/           SupabaseClient.swift (PostgREST/GoTrue over URLSession),
                  Repositories.swift (protocols + Dependencies)
  Data/           SupabaseRepositories.swift — one per screen
  Features/       Home · Recommendations · Catalogue · Chat · Profile · Invoices
  App/            AppRoot.swift (session + routing), RootView.swift (tabs, sign-in)
  Preview/        SampleData.swift (screenshot fixtures), Previews.swift
```

## Deliberate departures from the original

Kept because they are bugs, not style:

- the refresh banner wraps instead of truncating to `De nouveaux éléments sont di…`
- amounts render as `1000 €` (grouping off) to match the source exactly
- loading, empty and error states exist, which the original appears to lack
- every stepper row carries a VoiceOver label

## Open fidelity questions

- The real typeface looks like a geometric sans (Poppins / Figtree family); all
  sizes route through `Theme.Typography`, so swapping it is one file.
- Colours are sampled from screenshots, not from source. Same, one file.
- The `.failed` stepper state is inferred — no lost/refused recommendation has
  been seen yet.
