-- Energy Courtage — closing the money loop, and managing members.
--
-- Until now a reward could reach 'invoiced' and stop there: nothing in the
-- system ever said it had been paid. That is the state the apporteur cares
-- about most.

-- ============================================================== payouts
-- These two tables were sketched in the plan and never created: the schema
-- had a reward_status of 'paid' with nothing in the system able to set it.

create table payout_batches (
  id          uuid primary key default gen_random_uuid(),
  period      text not null,               -- YYYY-MM, how a transfer run is filed
  total       numeric(12,2) not null,
  reference   text,                        -- the bank's own reference
  notes       text,
  executed_at timestamptz not null default now(),
  executed_by uuid not null references profiles(id),
  created_at  timestamptz not null default now()
);

create table commissions (
  id                uuid primary key default gen_random_uuid(),
  recommendation_id uuid not null references recommendations(id) on delete restrict,
  profile_id        uuid not null references profiles(id) on delete restrict,
  invoice_id        uuid references invoices(id),
  amount            numeric(10,2) not null,
  status            reward_status not null default 'earned',
  earned_at         date,
  paid_at           timestamptz,
  payout_batch_id   uuid references payout_batches(id),
  created_at        timestamptz not null default now()
);

create index commissions_profile_idx on commissions (profile_id, created_at desc);
create index commissions_batch_idx   on commissions (payout_batch_id);

-- Pays a set of signed invoices in one batch, which is how a bank transfer run
-- actually happens: one file, many beneficiaries, one date.
create or replace function public.create_payout_batch(
  p_invoice_ids uuid[],
  p_reference   text default null
)
returns payout_batches
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_batch payout_batches%rowtype;
  v_total numeric(12,2);
  v_count int;
begin
  if not is_admin(v_actor) then
    raise exception 'only an admin may pay' using errcode = '42501';
  end if;

  -- An unsigned invoice is not payable: the apporteur has not agreed to it.
  select count(*) into v_count
  from invoices
  where id = any(p_invoice_ids) and status <> 'signed';

  if v_count > 0 then
    raise exception 'batch contains % invoice(s) that are not signed', v_count
      using errcode = '22023';
  end if;

  select coalesce(sum(amount_ttc), 0) into v_total
  from invoices where id = any(p_invoice_ids);

  if v_total = 0 then
    raise exception 'nothing to pay' using errcode = '22023';
  end if;

  insert into payout_batches (period, total, executed_at, executed_by, reference)
  values (to_char(now(), 'YYYY-MM'), v_total, now(), v_actor, p_reference)
  returning * into v_batch;

  insert into commissions (recommendation_id, profile_id, amount, status,
                           earned_at, paid_at, payout_batch_id, invoice_id)
  select i.recommendation_id, i.apporteur_id, i.amount_ttc, 'paid',
         i.issued_on, now(), v_batch.id, i.id
  from invoices i where i.id = any(p_invoice_ids);

  update invoices set status = 'paid' where id = any(p_invoice_ids);

  update recommendations r
     set reward_status = 'paid'
    from invoices i
   where i.id = any(p_invoice_ids) and r.id = i.recommendation_id;

  -- tell each apporteur their money is on the way
  insert into notifications (profile_id, kind, payload)
  select distinct i.apporteur_id, 'payout_sent',
         jsonb_build_object('batch_id', v_batch.id,
                            'invoice_number', i.number,
                            'amount', i.amount_ttc)
  from invoices i where i.id = any(p_invoice_ids);

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_actor, 'payout_batches', v_batch.id, 'create_payout_batch',
          jsonb_build_object('total', v_total, 'invoices', array_length(p_invoice_ids, 1)));

  return v_batch;
end;
$$;

alter table payout_batches enable row level security;
alter table commissions enable row level security;

-- The blanket grant in the RLS migration only covered the tables that existed
-- when it ran. Every table added later needs its own, or RLS never gets a
-- chance to decide anything -- the role is refused before it is consulted.
grant select, insert, update, delete on payout_batches to authenticated;
grant select, insert, update, delete on commissions to authenticated;
grant select, insert, update, delete on invites to authenticated;
grant select, insert, update, delete on invoice_texts to authenticated;

create policy payout_batches_admin on payout_batches for all to authenticated
  using ((select is_admin((select auth.uid()))))
  with check ((select is_admin((select auth.uid()))));

-- An apporteur sees their own commission lines; only an admin sees everyone's.
create policy commissions_read on commissions for select to authenticated
  using (profile_id = (select auth.uid()) or (select is_admin((select auth.uid()))));
create policy commissions_write on commissions for all to authenticated
  using ((select is_admin((select auth.uid()))))
  with check ((select is_admin((select auth.uid()))));

-- What the admin's payables screen reads: everything signed and not yet paid.
create view payable_invoices with (security_invoker = true) as
select
  i.id                as invoice_id,
  i.number,
  i.issued_on,
  i.amount_ttc,
  i.apporteur_id,
  p.first_name || ' ' || p.last_name as apporteur_name,
  p.iban_encrypted is not null       as has_bank_details,
  r.id                as recommendation_id,
  r.filleul_first_name || ' ' || r.filleul_last_name as filleul
from invoices i
join profiles p on p.id = i.apporteur_id
join recommendations r on r.id = i.recommendation_id
where i.status = 'signed';

grant select on payable_invoices to authenticated;

-- ============================================================== members
create or replace function public.set_member_status(
  p_profile_id uuid,
  p_status     profile_status
)
returns profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile profiles%rowtype;
begin
  if not is_admin(auth.uid()) then
    raise exception 'only an admin may change a member''s status'
      using errcode = '42501';
  end if;
  if p_profile_id = auth.uid() then
    -- An admin suspending themselves can lock the last one out entirely.
    raise exception 'you cannot change your own status' using errcode = '22023';
  end if;

  update profiles set status = p_status where id = p_profile_id
  returning * into v_profile;
  if not found then
    raise exception 'no such member' using errcode = 'P0002';
  end if;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (auth.uid(), 'profiles', p_profile_id, 'set_status',
          jsonb_build_object('status', p_status));
  return v_profile;
end;
$$;

-- The admin's member list, with the activity that decides who to chase.
create view member_overview with (security_invoker = true) as
select
  p.id,
  p.first_name || ' ' || p.last_name as full_name,
  p.email,
  p.phone,
  p.role,
  p.status,
  p.vat_liable,
  p.billing_mandate_signed_at is not null as has_mandate,
  p.created_at,
  count(r.id) filter (where r.deleted_at is null)                as total_recommendations,
  count(r.id) filter (where r.status = 'active' and r.deleted_at is null) as active_recommendations,
  coalesce(sum(r.reward_amount) filter (where r.reward_status = 'paid'), 0)  as paid_total,
  coalesce(sum(r.reward_amount) filter (where r.reward_status in ('earned','invoiced')), 0) as owed_total,
  max(r.created_at) as last_recommendation_at
from profiles p
left join recommendations r on r.parrain_id = p.id
group by p.id;

grant select on member_overview to authenticated;
