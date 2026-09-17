-- Energy Courtage — read models.
--
-- The card needs a recommendation plus its whole timeline plus whether a
-- contract exists. Fetched naively that is one query per card per stage; this
-- view returns everything the list renders in a single round trip.
--
-- security_invoker means the view is evaluated with the caller's rights, so
-- the RLS policies on the underlying tables still apply. Without it, the view
-- would quietly become a hole straight through them.
create view recommendation_feed with (security_invoker = true) as
select
  r.id,
  r.filleul_first_name,
  r.filleul_last_name,
  r.filleul_phone,
  p.first_name || ' ' || p.last_name as parrain_name,
  r.parrain_id,
  r.created_at,
  s.key   as current_stage_key,
  s.label as current_stage_label,
  r.reward_amount,
  r.reward_status,
  r.status,
  -- the amount is only surfaced once the reward has actually been triggered,
  -- which is why an in-progress card shows no figure
  case when r.reward_status = 'pending' then null else r.reward_amount end
    as displayed_amount,
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
  ) as invoice_number
from recommendations r
join profiles p on p.id = r.parrain_id
join stages   s on s.id = r.current_stage_id
where r.deleted_at is null;

grant select on recommendation_feed to authenticated;

-- The Accueil KPIs. SECURITY INVOKER by default, so an apporteur's totals are
-- computed over his own rows and an admin's over everything.
create or replace function public.dashboard_stats()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'active_count',   count(*) filter (where status = 'active'),
    'archived_count', count(*) filter (where status <> 'active'),
    'pending_total',  coalesce(sum(reward_amount) filter (where reward_status = 'pending'), 0),
    'earned_total',   coalesce(sum(reward_amount) filter (where reward_status in ('earned','invoiced')), 0),
    'paid_total',     coalesce(sum(reward_amount) filter (where reward_status = 'paid'), 0),
    'conversion_rate',
      case when count(*) = 0 then 0
           else round(100.0 * count(*) filter (where reward_status <> 'pending') / count(*), 1)
      end
  )
  from recommendations
  where deleted_at is null;
$$;
