-- Energy Courtage — find pgcrypto where Supabase keeps it.
--
-- stamp_invoice_digest() pins its search_path to `public, pg_temp` and calls
-- digest(). On Supabase, pgcrypto lives in the `extensions` schema, so on a
-- hosted project the call does not resolve and EVERY invoice insert fails --
-- issuing an invoice, the whole money path, broken on the first try. Locally
-- pgcrypto sat in `public`, which is why no test noticed; the local stand-in
-- now puts it in `extensions`, as Supabase does, and this is what that found.
--
-- stamp_legal_document() took the caller's path, which happened to work; it
-- is pinned too, so it never depends on who calls it.
alter function public.stamp_invoice_digest() set search_path = public, extensions, pg_temp;
alter function public.stamp_legal_document() set search_path = public, extensions, pg_temp;
