# EnergyCourtage — iOS

SwiftUI package for the collaborator/admin app. One binary serves both roles:
the list, card, stepper and dialogs are shared, and `UserRole` gates the
admin-only affordances (`Valider l'étape`, and later the action sheet and the
company signature panel). Authority is enforced in Postgres — see
`supabase/migrations/…_rls.sql`. The role check here is presentation only.

## Status

| | |
|---|---|
| Built | Design tokens, 4-state stepper, card, comment dialog, segmented control, search, refresh banner, buttons, `Recommandations` screen with loading/empty/error states, view model, in-memory repository, unit tests |
| Not built yet | Supabase repository, the other four tabs, create-reco form, invoice + signature UI, action sheet, push |

**Not yet compiled.** This package was written on Linux, where no Swift
toolchain is available, so it has had a careful read-through but not a build.
Expect to fix a few small things on first `swift build` / Xcode open.

## Run it

```bash
open ios/Package.swift        # Xcode 15+, iOS 17 target
swift test                    # logic tests (no UI)
```

Four previews reproduce the reference screenshots: the completed Thomas Dubois
card, the same card mid-pipeline (completed / current / pending together), the
stage comment dialog, and the full screen in both roles.

## Layout

```
Sources/EnergyCourtage/
  DesignSystem/   Theme.swift (all tokens), StageStepper.swift, Controls.swift
  Models/         Domain.swift — Stage, StageEvent, Recommendation, UserRole
  Features/       Recommendations/ — card, screen, view model
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
