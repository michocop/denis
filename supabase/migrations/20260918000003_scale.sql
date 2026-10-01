-- Energy Courtage — making it hold up with thousands of apporteurs.
--
-- Measured against 2 000 apporteurs and 40 000 recommendations before writing
-- any of this. The numbers that motivated each change are in the comments.

create extension if not exists pg_trgm;

-- ===================================================== RLS, made indexable
--
-- A policy written `parrain_id = auth.uid() or is_admin(auth.uid())` is
-- evaluated ONCE PER ROW, and the OR stops the planner using the index on
-- parrain_id at all -- an apporteur's own dashboard was scanning all 40 000
-- rows to aggregate 14 of them (211 ms).
--
-- Wrapping each call in a scalar subquery turns it into an InitPlan: Postgres
-- evaluates it once for the whole statement and can then use the index. Same
-- policy, same meaning, two orders of magnitude apart.

drop policy if exists reco_select on recommendations;
create policy reco_select on recommendations for select to authenticated
  using (
    (parrain_id = (select auth.uid()) and deleted_at is null)
    or (select is_admin((select auth.uid())))
  );

drop policy if exists reco_insert on recommendations;
create policy reco_insert on recommendations for insert to authenticated
  with check (parrain_id = (select auth.uid())
              and (select is_active_member((select auth.uid()))));

drop policy if exists reco_update on recommendations;
create policy reco_update on recommendations for update to authenticated
  using ((parrain_id = (select auth.uid()) and deleted_at is null)
         or (select is_admin((select auth.uid()))))
  with check ((parrain_id = (select auth.uid()) and deleted_at is null)
              or (select is_admin((select auth.uid()))));

drop policy if exists reco_delete on recommendations;
create policy reco_delete on recommendations for delete to authenticated
  using ((select is_admin((select auth.uid()))));

drop policy if exists profiles_select on profiles;
create policy profiles_select on profiles for select to authenticated
  using (id = (select auth.uid()) or (select is_admin((select auth.uid()))));

drop policy if exists invoice_select on invoices;
create policy invoice_select on invoices for select to authenticated
  using (apporteur_id = (select auth.uid())
         or (select is_admin((select auth.uid()))));

drop policy if exists notes_own on personal_notes;
create policy notes_own on personal_notes for all to authenticated
  using (author_id = (select auth.uid()))
  with check (author_id = (select auth.uid()));

drop policy if exists notifications_own on notifications;
create policy notifications_own on notifications for all to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

drop policy if exists messages_select on messages;
create policy messages_select on messages for select to authenticated
  using ((select is_thread_participant(messages.thread_id, (select auth.uid()))));

-- ============================================================== searching
--
-- The app filtered in Swift, which means every search downloaded the whole
-- list first. parrain_name is denormalised because an admin searches by
-- apporteur as well as by filleul, and a join to profiles cannot be covered by
-- one trigram index.

alter table recommendations
  add column parrain_name text,
  add column search_text  text;

create or replace function public.refresh_recommendation_search()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  select p.first_name || ' ' || p.last_name into new.parrain_name
    from profiles p where p.id = new.parrain_id;

  new.search_text := lower(concat_ws(' ',
    new.filleul_first_name, new.filleul_last_name, new.filleul_company,
    new.filleul_phone, new.filleul_email, new.parrain_name));
  return new;
end;
$$;

create trigger recos_refresh_search
  before insert or update of filleul_first_name, filleul_last_name,
                             filleul_company, filleul_phone, filleul_email, parrain_id
  on recommendations
  for each row execute function public.refresh_recommendation_search();

-- An apporteur who changes their name must not disappear from searches.
create or replace function public.cascade_profile_name()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.first_name is distinct from old.first_name
     or new.last_name is distinct from old.last_name then
    update recommendations
       set parrain_name = new.first_name || ' ' || new.last_name,
           search_text = lower(concat_ws(' ',
             filleul_first_name, filleul_last_name, filleul_company,
             filleul_phone, filleul_email, new.first_name || ' ' || new.last_name))
     where parrain_id = new.id;
  end if;
  return new;
end;
$$;

create trigger profiles_cascade_name after update on profiles
  for each row execute function public.cascade_profile_name();

update recommendations r
   set parrain_name = p.first_name || ' ' || p.last_name,
       search_text = lower(concat_ws(' ',
         r.filleul_first_name, r.filleul_last_name, r.filleul_company,
         r.filleul_phone, r.filleul_email, p.first_name || ' ' || p.last_name))
  from profiles p where p.id = r.parrain_id;

create index recommendations_search_idx
  on recommendations using gin (search_text gin_trgm_ops);

-- ================================================================ indexes
-- Ordered to match how the list is actually read: newest first, within a
-- status, excluding deleted rows.
create index recommendations_active_idx
  on recommendations (status, created_at desc, id desc)
  where deleted_at is null;

create index recommendations_parrain_recent_idx
  on recommendations (parrain_id, created_at desc, id desc)
  where deleted_at is null;

create index recommendations_admin_idx
  on recommendations (assigned_admin_id, created_at desc)
  where deleted_at is null;

create index stage_events_reco_idx
  on recommendation_stage_events (recommendation_id, completed_at desc)
  where reverted_at is null;

create index invoices_reco_idx on invoices (recommendation_id, created_at desc);
create index notifications_unread_idx
  on notifications (profile_id, created_at desc) where read_at is null;
create index thread_participants_profile_idx on thread_participants (profile_id);
create index reminders_due_idx on reminders (due_at) where status = 'scheduled';
create index personal_notes_lookup_idx on personal_notes (author_id, recommendation_id);

-- ============================================================= pagination
--
-- The admin list returned 24 025 rows in one response. Keyset pagination --
-- "everything older than the last row I saw" -- instead of OFFSET, because
-- OFFSET re-reads and discards every skipped row, so page 200 costs 200 times
-- page 1, and rows shifting underneath make it skip or repeat entries.
create or replace function public.recommendation_page(
  p_archived      boolean default false,
  p_search        text    default null,
  p_cursor_at     timestamptz default null,
  p_cursor_id     uuid    default null,
  p_limit         int     default 20
)
returns setof recommendation_feed
language sql
stable
as $$
  -- The page of ids is chosen on the base table FIRST, so the trigram index
  -- is usable and the view's per-row subqueries (timeline, invoice, note,
  -- reminders) run for twenty rows rather than for the whole result set.
  -- Filtering inside the view instead cost 128 ms; this costs single digits.
  select f.*
  from recommendation_feed f
  join (
    select r.id, r.created_at
    from recommendations r
    where r.deleted_at is null
      and (case when p_archived then r.status <> 'active' else r.status = 'active' end)
      and (p_search is null or p_search = ''
           or r.search_text like '%' || lower(p_search) || '%')
      and (p_cursor_at is null
           or (r.created_at, r.id) < (p_cursor_at, p_cursor_id))
    order by r.created_at desc, r.id desc
    limit least(greatest(p_limit, 1), 100)
  ) page on page.id = f.id
  order by f.created_at desc, f.id desc;
$$;

analyze;
