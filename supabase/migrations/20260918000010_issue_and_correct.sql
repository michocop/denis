-- Energy Courtage — issuing an invoice, and correcting one.
--
-- Two holes that only show up when you follow the money the whole way.
--
-- 1. NOTHING CREATED AN INVOICE. Advancing a recommendation to the reward
--    stage sets reward_status = 'earned' and stops there. Everything after
--    that point -- gapless numbering, the VAT derivation, the mandate gate,
--    the digest, both signatures, the PDF, the payout batch -- was built and
--    tested against invoices that only the seed had ever inserted. In a real
--    project no invoice would ever have existed, and the whole second half
--    of the admin app would have been unreachable.
--
-- 2. NOTHING ISSUED A CREDIT NOTE. A signed invoice is sealed and cannot be
--    deleted; the delete guard's own error message says to use an avoir, and
--    the handover runbook tells the client to issue one. There was no way to.
--    "Correct it in the database" is not an answer for a document that is
--    part of a numbered series.

-- ------------------------------------------------------------ issuing one
-- The amount is the reward already agreed on the recommendation, never a
-- number typed at issuing time: the apporteur has seen that figure in the
-- app, and an invoice that disagrees with it is an argument.
create or replace function public.issue_invoice(
  p_recommendation_id uuid,
  p_prestation_label  text default 'Apport d''affaires - mise en relation'
)
returns invoices
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_reco   recommendations%rowtype;
  v_issuer profiles%rowtype;
  v_inv    invoices%rowtype;
begin
  if not is_admin(v_uid) then
    raise exception 'only an administrator issues an invoice' using errcode = '42501';
  end if;

  select * into v_reco from recommendations
   where id = p_recommendation_id and deleted_at is null;
  if not found then
    raise exception 'recommendation not found' using errcode = 'P0002';
  end if;

  if v_reco.reward_status = 'pending' then
    raise exception 'this recommendation has not reached the reward stage yet'
      using errcode = '42501';
  end if;

  if v_reco.reward_amount is null or v_reco.reward_amount <= 0 then
    raise exception 'set the commission on the recommendation before invoicing it'
      using errcode = '42501';
  end if;

  -- One live invoice per recommendation. A second one would be a duplicate
  -- claim on the same commission, and the numbering makes it permanent.
  if exists (select 1 from invoices
              where recommendation_id = p_recommendation_id
                and status <> 'void') then
    raise exception 'this recommendation already has an invoice'
      using errcode = '23505';
  end if;

  select * into v_issuer from profiles where id = v_uid;

  -- vat_mode, vat_rate, vat_amount, amount_ttc, legal_mentions, tax_notice,
  -- number and document_sha256 are all set by triggers. The mandate gate runs
  -- here too, so an apporteur with no mandate on file is refused rather than
  -- invoiced in their name.
  insert into invoices (recommendation_id, apporteur_id, issuer_id,
                        prestation_label, intervened_on, place, amount_ht)
  values (p_recommendation_id, v_reco.parrain_id, v_uid,
          p_prestation_label,
          coalesce((select max(completed_at)::date
                      from recommendation_stage_events
                     where recommendation_id = p_recommendation_id
                       and reverted_at is null), current_date),
          coalesce(v_issuer.city, ''),
          v_reco.reward_amount)
  returning * into v_inv;

  update recommendations set reward_status = 'invoiced', updated_at = now()
   where id = p_recommendation_id and reward_status = 'earned';

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_uid, 'invoices', v_inv.id, 'issue_invoice',
          jsonb_build_object('recommendation_id', p_recommendation_id,
                             'amount_ht', v_inv.amount_ht));

  -- re-read: the triggers have filled in everything above
  select * into v_inv from invoices where id = v_inv.id;
  return v_inv;
end;
$$;

-- --------------------------------------------------------- correcting one
-- An avoir is a new invoice in the same series carrying the negative amount,
-- not an edit and not a deletion. That is what keeps the series continuous
-- (art. 242 nonies A ann. II CGI) while cancelling the original's effect.
alter table invoices add column corrects_invoice_id uuid references invoices(id);

comment on column invoices.corrects_invoice_id is
  'Set on a credit note (avoir); points at the invoice it cancels.';

-- amount_ht > 0 was right when every invoice was a sale. A credit note is the
-- same document with the sign reversed, so the rule becomes "not zero".
alter table invoices drop constraint invoice_amount_positive;
alter table invoices add constraint invoice_amount_not_zero
  check (amount_ht <> 0);

-- A credit note may only cancel a sealed invoice, and only once.
create unique index invoice_one_credit_note
  on invoices (corrects_invoice_id) where corrects_invoice_id is not null;

create or replace function public.create_credit_note(
  p_invoice_id uuid,
  p_reason     text
)
returns invoices
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := auth.uid();
  v_orig invoices%rowtype;
  v_note invoices%rowtype;
begin
  if not is_admin(v_uid) then
    raise exception 'only an administrator issues a credit note' using errcode = '42501';
  end if;

  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'a credit note must say why it was issued' using errcode = '22023';
  end if;

  select * into v_orig from invoices where id = p_invoice_id;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;

  if v_orig.corrects_invoice_id is not null then
    raise exception 'a credit note cannot itself be credited' using errcode = '42501';
  end if;

  if v_orig.status not in ('signed', 'paid') then
    raise exception
      'only a signed invoice needs a credit note: this one can still be voided'
      using errcode = '42501';
  end if;

  insert into invoices (recommendation_id, apporteur_id, issuer_id,
                        prestation_label, intervened_on, place, amount_ht,
                        corrects_invoice_id)
  values (v_orig.recommendation_id, v_orig.apporteur_id, v_uid,
          'Avoir sur facture ' || v_orig.number || ' — ' || btrim(p_reason),
          v_orig.intervened_on, v_orig.place, -v_orig.amount_ht,
          v_orig.id)
  returning * into v_note;

  -- the commission is owed again, so the recommendation can be re-invoiced
  update recommendations set reward_status = 'earned', updated_at = now()
   where id = v_orig.recommendation_id;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_uid, 'invoices', v_note.id, 'create_credit_note',
          jsonb_build_object('corrects', v_orig.id, 'reason', p_reason));

  select * into v_note from invoices where id = v_note.id;
  return v_note;
end;
$$;

-- A credited invoice is settled, so it must drop off the payables list --
-- otherwise the company pays an invoice it has just cancelled.
create or replace view payable_invoices with (security_invoker = true) as
select
  i.id                as invoice_id,
  i.number,
  i.issued_on,
  i.amount_ttc,
  i.apporteur_id,
  p.first_name || ' ' || p.last_name as apporteur_name,
  p.bank_details_on_file             as has_bank_details,
  r.id                as recommendation_id,
  r.filleul_first_name || ' ' || r.filleul_last_name as filleul
from invoices i
join profiles p on p.id = i.apporteur_id
join recommendations r on r.id = i.recommendation_id
where i.status = 'signed'
  and i.corrects_invoice_id is null
  and not exists (select 1 from invoices c where c.corrects_invoice_id = i.id);

grant select on payable_invoices to authenticated;

-- The invoice_insert policy stays. Dropping it was tempting -- issue_invoice
-- is the only path that enforces "the amount is the agreed reward" and "one
-- live invoice per recommendation" -- but it buys nothing: an admin with
-- dashboard access inserts through the SQL console regardless of RLS. What it
-- would cost is the direct-insert tests that cover gapless numbering, the VAT
-- derivation and the mandate gate, which are worth more than a guard that
-- only stops the honest path.

-- ------------------------------------------- who can actually be paid
-- member_overview never exposed bank_details_on_file, and nothing in the app
-- called set_bank_details_on_file, so has_bank_details on the payables list
-- was false for everyone and the warning it raises could never be cleared.
-- Dropped and recreated rather than CREATE OR REPLACE: adding a column in the
-- middle renames the ones after it, which Postgres refuses outright.
drop view if exists member_overview;
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
  p.bank_details_on_file,
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
