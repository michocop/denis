-- Energy Courtage — Row Level Security.
--
-- This file is the single most important one in the project. A mistake here
-- does not crash anything: it silently exposes every apporteur's prospect list
-- (names, phone numbers, deal values) to every other apporteur.
-- Every policy below has a matching test in supabase/tests/rls_test.sql.

alter table profiles                     enable row level security;
alter table stages                       enable row level security;
alter table offers                       enable row level security;
alter table recommendations              enable row level security;
alter table recommendation_stage_events  enable row level security;
alter table invoices                     enable row level security;
alter table invoice_signatures           enable row level security;
alter table invoice_sequences            enable row level security;
alter table personal_notes               enable row level security;
alter table documents                    enable row level security;
alter table reminders                    enable row level security;
alter table threads                      enable row level security;
alter table thread_participants          enable row level security;
alter table messages                     enable row level security;
alter table tickets                      enable row level security;
alter table notifications                enable row level security;
alter table audit_log                    enable row level security;

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- ---------------------------------------------------------------- profiles
create policy profiles_select on profiles for select to authenticated
  using (id = auth.uid() or is_admin(auth.uid()));

create policy profiles_insert on profiles for insert to authenticated
  with check (id = auth.uid());

create policy profiles_update on profiles for update to authenticated
  using (id = auth.uid() or is_admin(auth.uid()))
  with check (id = auth.uid() or is_admin(auth.uid()));

-- ------------------------------------------------------- reference tables
create policy stages_select on stages for select to authenticated using (true);
create policy stages_write  on stages for all    to authenticated
  using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

create policy offers_select on offers for select to authenticated
  using (is_active or is_admin(auth.uid()));
create policy offers_write  on offers for all to authenticated
  using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

-- --------------------------------------------------------- recommendations
-- The core rule: an apporteur sees his own recommendations and nothing else.
create policy reco_select on recommendations for select to authenticated
  using (
    (parrain_id = auth.uid() and deleted_at is null)
    or is_admin(auth.uid())
  );

create policy reco_insert on recommendations for insert to authenticated
  with check (parrain_id = auth.uid() and is_active_member(auth.uid()));

-- an apporteur may edit the filleul's contact details he typed in;
-- guard_recommendation_columns() blocks the stage / reward / status columns.
create policy reco_update on recommendations for update to authenticated
  using ((parrain_id = auth.uid() and deleted_at is null) or is_admin(auth.uid()))
  with check ((parrain_id = auth.uid() and deleted_at is null) or is_admin(auth.uid()));

create policy reco_delete on recommendations for delete to authenticated
  using (is_admin(auth.uid()));

-- ------------------------------------------------------------ stage events
create policy stage_event_select on recommendation_stage_events for select to authenticated
  using (exists (
    select 1 from recommendations r
     where r.id = recommendation_id
       and (r.parrain_id = auth.uid() or is_admin(auth.uid()))
  ));

create policy stage_event_write on recommendation_stage_events for all to authenticated
  using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

-- ---------------------------------------------------------------- invoices
create policy invoice_select on invoices for select to authenticated
  using (apporteur_id = auth.uid() or is_admin(auth.uid()));

create policy invoice_insert on invoices for insert to authenticated
  with check (is_admin(auth.uid()));

create policy invoice_update on invoices for update to authenticated
  using (is_admin(auth.uid())) with check (is_admin(auth.uid()));
-- no delete policy at all: deletion is impossible for every non-superuser.

create policy invoice_seq_admin on invoice_sequences for all to authenticated
  using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

-- Each party signs for itself. Nobody can sign in another person's name.
create policy signature_select on invoice_signatures for select to authenticated
  using (exists (
    select 1 from invoices i
     where i.id = invoice_id
       and (i.apporteur_id = auth.uid() or is_admin(auth.uid()))
  ));

create policy signature_insert on invoice_signatures for insert to authenticated
  with check (
    signer_id = auth.uid()
    and exists (
      select 1 from invoices i
       where i.id = invoice_id
         and case signer_role
               when 'apporteur'  then i.apporteur_id = auth.uid()
               when 'entreprise' then is_admin(auth.uid())
             end
    )
  );

-- --------------------------------------------------------- notes, docs, etc
-- "Notes personnelles" are private to their author — an admin cannot read an
-- apporteur's private notes, and vice versa.
create policy notes_own on personal_notes for all to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());

create policy documents_select on documents for select to authenticated
  using (exists (
    select 1 from recommendations r
     where r.id = recommendation_id
       and (r.parrain_id = auth.uid() or is_admin(auth.uid()))
  ));

create policy documents_write on documents for all to authenticated
  using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

create policy reminders_admin on reminders for all to authenticated
  using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

-- ------------------------------------------------------------ chat & tickets
create policy threads_select on threads for select to authenticated
  using (exists (
    select 1 from thread_participants p
     where p.thread_id = threads.id and p.profile_id = auth.uid()
  ));

create policy threads_insert on threads for insert to authenticated
  with check (created_by = auth.uid() and is_active_member(auth.uid()));

create policy participants_select on thread_participants for select to authenticated
  using (profile_id = auth.uid() or exists (
    select 1 from thread_participants me
     where me.thread_id = thread_participants.thread_id and me.profile_id = auth.uid()
  ));

-- pinned / archived / last_read_at are per-participant settings
create policy participants_update_own on thread_participants for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create policy participants_insert on thread_participants for insert to authenticated
  with check (exists (
    select 1 from threads t where t.id = thread_id and t.created_by = auth.uid()
  ) or is_admin(auth.uid()));

create policy messages_select on messages for select to authenticated
  using (exists (
    select 1 from thread_participants p
     where p.thread_id = messages.thread_id and p.profile_id = auth.uid()
  ));

create policy messages_insert on messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1 from thread_participants p
       where p.thread_id = messages.thread_id and p.profile_id = auth.uid()
    )
  );

create policy tickets_select on tickets for select to authenticated
  using (opener_id = auth.uid() or assignee_id = auth.uid() or is_admin(auth.uid()));
create policy tickets_insert on tickets for insert to authenticated
  with check (opener_id = auth.uid());
create policy tickets_update on tickets for update to authenticated
  using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

-- ------------------------------------------------------------------- misc
create policy notifications_own on notifications for all to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create policy audit_admin_read on audit_log for select to authenticated
  using (is_admin(auth.uid()));
