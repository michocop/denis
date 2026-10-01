-- Energy Courtage — the things the source app appears to lack.
--
-- Each of these came out of reading the screenshots and asking what happens
-- on the day the product is busy rather than the day it is demonstrated.

-- ============================================================ duplicates
-- Two apporteurs recommending the same person is not a hypothetical: it is the
-- single most expensive dispute this kind of business has, because both expect
-- the commission. The source app's create flow shows no sign of checking.
-- Phone numbers are compared on digits alone, since one person will type
-- "+33 6 75 75 75 75" and another "0675757575".
create or replace function public.normalise_phone(p_phone text)
returns text
language sql
immutable
as $$
  select nullif(right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 9), '');
$$;

create index recommendations_phone_idx
  on recommendations (normalise_phone(filleul_phone))
  where deleted_at is null;

create index recommendations_email_idx
  on recommendations (lower(filleul_email))
  where deleted_at is null;

-- Deliberately SECURITY DEFINER and deliberately thin: an apporteur must be
-- warned that someone already holds this lead WITHOUT learning who the other
-- apporteur is, or anything else about their pipeline.
create or replace function public.check_duplicate_filleul(
  p_phone text default null,
  p_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  v_mine  int;
  v_other int;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select
    count(*) filter (where parrain_id = v_uid),
    count(*) filter (where parrain_id <> v_uid)
  into v_mine, v_other
  from recommendations
  where deleted_at is null
    and status = 'active'
    and (
      (normalise_phone(p_phone) is not null
       and normalise_phone(filleul_phone) = normalise_phone(p_phone))
      or (nullif(lower(p_email), '') is not null
          and lower(filleul_email) = lower(p_email))
    );

  return jsonb_build_object(
    'already_yours', v_mine > 0,
    'held_by_someone_else', v_other > 0
  );
end;
$$;

-- ======================================================== stage staleness
-- A recommendation that has sat in one stage for a fortnight is the thing an
-- admin most needs to see, and nothing in the source app surfaces it.
drop view if exists recommendation_feed;

create view recommendation_feed with (security_invoker = true) as
select
  r.id,
  r.filleul_first_name,
  r.filleul_last_name,
  r.filleul_phone,
  r.filleul_email,
  p.first_name || ' ' || p.last_name as parrain_name,
  r.parrain_id,
  r.assigned_admin_id,
  r.created_at,
  s.key   as current_stage_key,
  s.label as current_stage_label,
  r.reward_amount,
  r.reward_status,
  r.status,
  case when r.reward_status = 'pending' then null else r.reward_amount end
    as displayed_amount,
  -- days since the last thing that happened, whatever it was
  greatest(0, extract(day from now() - greatest(
    r.created_at,
    coalesce((select max(completed_at) from recommendation_stage_events e
               where e.recommendation_id = r.id and e.reverted_at is null), r.created_at)
  ))::int) as days_since_activity,
  (
    select coalesce(jsonb_agg(jsonb_build_object(
             'stage_key',    st.key,
             'stage_label',  st.label,
             'position',     st.position,
             'comment',      e.comment,
             'completed_at', e.completed_at
           ) order by st.position), '[]'::jsonb)
    from recommendation_stage_events e
    join stages st on st.id = e.stage_id
    where e.recommendation_id = r.id and e.reverted_at is null
  ) as events,
  exists (
    select 1 from documents d
     where d.recommendation_id = r.id and d.kind in ('contract', 'invoice')
  ) as has_contract,
  (
    select i.number from invoices i
     where i.recommendation_id = r.id
     order by i.created_at desc limit 1
  ) as invoice_number,
  (
    select i.id from invoices i
     where i.recommendation_id = r.id
     order by i.created_at desc limit 1
  ) as invoice_id,
  exists (
    select 1 from personal_notes n
     where n.recommendation_id = r.id and n.author_id = auth.uid()
  ) as has_note,
  (
    select count(*) from reminders rm
     where rm.recommendation_id = r.id and rm.status = 'scheduled'
  ) as pending_reminders
from recommendations r
join profiles p on p.id = r.parrain_id
join stages   s on s.id = r.current_stage_id
where r.deleted_at is null;

grant select on recommendation_feed to authenticated;

-- ========================================================= notifications
-- Advancing a stage should tell the apporteur. Doing it in the database means
-- it happens however the stage was advanced -- app, console, or a script --
-- rather than only when someone remembered to call it from the client.
create or replace function public.notify_on_stage_event()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reco  recommendations%rowtype;
  v_stage stages%rowtype;
begin
  select * into v_reco from recommendations where id = new.recommendation_id;
  select * into v_stage from stages where id = new.stage_id;

  -- never notify someone about their own action
  if v_reco.parrain_id = new.completed_by then
    return null;
  end if;

  insert into notifications (profile_id, kind, payload)
  values (v_reco.parrain_id,
          case when v_stage.is_reward_trigger then 'reward_earned' else 'stage_advanced' end,
          jsonb_build_object(
            'recommendation_id', v_reco.id,
            'filleul', v_reco.filleul_first_name || ' ' || v_reco.filleul_last_name,
            'stage_key', v_stage.key,
            'stage_label', v_stage.label,
            'amount', v_reco.reward_amount
          ));
  return null;
end;
$$;

create trigger stage_event_notifies after insert on recommendation_stage_events
  for each row execute function public.notify_on_stage_event();

create or replace function public.unread_notification_count()
returns int
language sql
stable
as $$
  select count(*)::int from notifications
   where profile_id = auth.uid() and read_at is null;
$$;

create or replace function public.mark_notifications_read()
returns void
language sql
as $$
  update notifications set read_at = now()
   where profile_id = auth.uid() and read_at is null;
$$;

-- ============================================================= reminders
create or replace function public.schedule_reminder(
  p_recommendation_id uuid,
  p_label             text,
  p_due_at            timestamptz
)
returns reminders
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_reminder reminders%rowtype;
begin
  if not is_admin(auth.uid()) then
    raise exception 'only an admin may schedule a reminder' using errcode = '42501';
  end if;
  if p_due_at <= now() then
    raise exception 'a reminder must be in the future' using errcode = '22023';
  end if;

  insert into reminders (recommendation_id, created_by, label, due_at)
  values (p_recommendation_id, auth.uid(), p_label, p_due_at)
  returning * into v_reminder;
  return v_reminder;
end;
$$;

create or replace function public.complete_reminder(p_reminder_id uuid)
returns void
language sql
as $$
  update reminders set status = 'done'
   where id = p_reminder_id and status = 'scheduled';
$$;

-- =================================================== commission statement
-- What an apporteur needs at tax time, and what the source app's final-stage
-- message tells them to produce, without giving them anything to produce it
-- from.
create view commission_statement with (security_invoker = true) as
select
  r.parrain_id,
  extract(year from coalesce(i.issued_on, r.created_at))::int as year,
  r.id as recommendation_id,
  r.filleul_first_name || ' ' || r.filleul_last_name as filleul,
  r.reward_amount,
  r.reward_status,
  i.number  as invoice_number,
  i.issued_on,
  i.amount_ht,
  i.amount_ttc,
  i.status  as invoice_status
from recommendations r
left join invoices i on i.recommendation_id = r.id
where r.deleted_at is null
  and r.reward_status in ('earned', 'invoiced', 'paid');

grant select on commission_statement to authenticated;
