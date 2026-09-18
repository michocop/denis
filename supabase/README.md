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
then `tests/rls_test.sql`. A clean run means all 168 assertions held.

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
| `…_chat.sql` | `thread_overview`, `message_feed`, and why names are exposed to chat only |
| `…_invoice_pdf.sql` | the private bucket, and writing the retained document once |
| `…_notifications.sql` | what gets notified, the text, and device tokens |

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

**A new table needs its own GRANT.** The blanket
`grant ... on all tables in schema public to authenticated` only covers tables
that existed when it ran. Without a grant the role is refused before RLS is
ever consulted, which reads as a permissions error rather than a policy one.

**Widening a policy widens every view over that table.** Letting conversation
participants read each other in `profiles` also let an apporteur who had once
messaged an admin see that admin in `member_overview`, which is a
`security_invoker` view over the same table. Chat gets names through two
SECURITY DEFINER functions that return a display name and nothing else,
rather than through a wider policy. The test suite caught this; a screenshot
would not have.

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

## Performance

`scripts/db_bench.sh` builds a synthetic database — 2 000 apporteurs, 40 000
recommendations, 80 000 stage events — and times the queries the app makes.
Run it after any schema change.

| | Before | After |
|---|---:|---:|
| Apporteur opens the list | 13 ms | 13 ms |
| Apporteur dashboard | **211 ms** | **7 ms** |
| Admin opens the list | **269 ms / 24 025 rows** | **9 ms / 20 rows** |
| Admin dashboard | **225 ms** | 10 ms |
| Search by filleul | **255 ms** (client-side, whole table) | 10 ms |
| Search by apporteur | not possible | 11 ms |

Three things caused all of it:

**A policy written `x = auth.uid() or is_admin(auth.uid())` runs once per
row**, and the OR stops the planner using the index on `x` at all — an
apporteur's own dashboard was scanning 40 000 rows to aggregate 14. Wrapping
each call in a scalar subquery — `(select auth.uid())` — makes it an InitPlan,
evaluated once per statement. Same policy, same meaning, thirty times faster.
Any new policy must follow the same shape.

**The list had no pagination.** `recommendation_page()` is keyset-paginated —
"everything older than the row I last saw" — rather than OFFSET, which
re-reads and discards every skipped row (page 200 costs 200× page 1) and
skips or repeats entries when rows shift underneath the reader.

**Search ran in Swift**, so every search downloaded the whole list first. It
is now a trigram index over a denormalised `search_text`, covering the filleul
*and* the apporteur's name. The denormalisation is maintained by trigger, and
the test suite checks that renaming an apporteur keeps their recommendations
findable.
