# Backend

Postgres schema, Row Level Security and the functions the app calls.

## Running the tests

They need any Postgres 14+; nothing Supabase-specific.

```bash
scripts/db_test.sh -h /tmp -p 5433 -U postgres
```

The script creates a throwaway database, applies `local/00_auth_shim.sql`
(which fakes `auth.users` and `auth.uid()` — **never apply it to a real
Supabase project**, which already has them), then every migration in order,
then `tests/rls_test.sql`. A clean run means all 71 assertions held.

## Deploying

```bash
supabase link --project-ref <ref>
supabase db push          # applies migrations/ only
psql "$DATABASE_URL" -f supabase/seed/demo.sql   # optional, non-production
```

## What lives where

| File | |
|---|---|
| `migrations/…_enums.sql` | every domain state machine |
| `…_tables.sql` | schema; stages, banners and comment templates are data, not code |
| `…_functions.sql` | role helpers, template rendering, gapless invoice numbering, `advance_stage`, `reset_pipeline` |
| `…_triggers.sql` | the rules RLS cannot express: column-level write guards, invoice sealing, delete guards |
| `…_rls.sql` | **the most important file in the project** |
| `…_seed_reference_data.sql` | the five stages and their copy, transcribed from the source app |
| `…_invoicing.sql` | VAT derivation, the self-billing mandate gate, the document contract |
| `…_feed.sql` | `recommendation_feed`, `dashboard_stats` |
| `…_workflow_rpcs.sql` | reassign, archive, soft delete, signing, chat |
| `…_document_digest.sql` | what exactly gets signed; account deletion |

## Three things worth knowing before changing anything

**RLS denies by matching zero rows, not by raising.** A policy mistake produces
an empty screen or a silently-skipped write, never an error. That is why
`assert_denied` in the test suite reads `ROW_COUNT` through `GET DIAGNOSTICS`
rather than `FOUND` — `EXECUTE` leaves `FOUND` untouched, so the first version
of that helper reported passes for denials that had not happened.

**A policy must never query its own table.** `thread_participants` did, and
every read recursed until Postgres refused the query. Membership and admin
checks go through SECURITY DEFINER helpers (`is_admin`, `is_thread_participant`,
`support_admin_id`) which sit outside RLS.

**Anything insertable needs a SELECT policy that can see its own new row.**
PostgREST asks for the inserted representation by default, so an INSERT whose
row is invisible to its own author fails outright. `threads` needed
`created_by = auth.uid()` in its SELECT policy for exactly this reason.

## Invoicing is the part with legal constraints

- Numbers come from a locked counter row, not a sequence: a sequence leaks
  numbers on rollback and the CGI requires a continuous series.
- VAT is derived from the apporteur's own `vat_liable` flag, never typed by an
  admin or a client.
- No invoice can be issued without a **self-billing mandate** that predates it.
- A signed invoice is sealed against every change but its payment status, and
  can never be deleted. Corrections go through a credit note.
- What is signed is `invoices.document_sha256`, derived by the database from the
  invoice's canonical text. The client signs that value rather than
  recomputing it, because a canonicalisation shared between Swift and SQL would
  have to stay byte-identical forever.
