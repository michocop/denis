# Energy Courtage — apporteur d'affaires platform

A clone of an energy-brokerage referral app, built from screenshots. One
iOS app serves both populations — the **apporteur** who introduces a
*filleul*, and the **entreprise** who works the pipeline, invoices and pays —
with a Postgres backend that owns every rule that matters.

## Layout

| | |
|---|---|
| `docs/PLAN.md` | screen-by-screen analysis of the source app, data model, effort breakdown, legal constraints |
| `supabase/` | schema, RLS, functions, migrations, 71-assertion test suite — see its README |
| `ios/` | SwiftUI package and app target — see its README |
| `scripts/db_test.sh` | applies the migrations to a throwaway database and runs the tests |

## Status

**Backend: built and verified.** 71 assertions pass against a real Postgres.
Covers isolation between apporteurs, the pipeline state machine, gapless
invoice numbering, VAT derivation, the self-billing mandate, signature
sealing and immutability, soft deletes, chat privacy and ticketing.

**iOS: written, not yet compiled.** No Swift toolchain exists on Linux, where
this was built. Every screen from the screenshots is implemented and wired to
a repository protocol with a Supabase implementation behind it. Expect a few
fixes on first `swift build`.

## Getting it running

```bash
# 1. backend
scripts/db_test.sh -h /tmp -p 5433 -U postgres      # prove it locally first
supabase link --project-ref <ref> && supabase db push

# 2. app
brew install xcodegen && cd ios && xcodegen generate
open EnergyCourtage.xcodeproj                        # set SUPABASE_URL / _ANON_KEY
```

Without XcodeGen: open `ios/Package.swift` for previews only, or create an
iOS App project and add `ios/` as a local package.

## The decisions worth knowing

**One app, two roles.** The list, card, stepper and dialogs are identical for
both populations; `UserRole` only decides which affordances appear. Authority
is enforced in Postgres — the role check in the client is presentation.

**The pipeline is data.** Stage labels, banner copy and the comment templates
that the source app clearly uses live in a table, so the funnel can be
reworded without shipping a build.

**Invoicing is a compliance subsystem, not a screen.** Numbers come from a
locked counter because a sequence leaks them on rollback; VAT is derived from
the apporteur's own tax status rather than typed; no invoice exists without a
prior self-billing mandate; a signed invoice is sealed and never deleted.

**RLS fails silently.** A policy mistake produces an empty screen, not an
error. That is why the test suite asserts denials explicitly, and why three
real defects — a recursive policy, an insert that could not read back its own
row, and a ticket assigned to nobody — were caught by tests rather than by
users.
