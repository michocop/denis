-- Energy Courtage — triggers.
-- These enforce the rules that RLS cannot express: column-level write
-- permissions, invoice immutability and the legal numbering.

create trigger profiles_touch    before update on profiles
  for each row execute function public.touch_updated_at();
create trigger recos_touch       before update on recommendations
  for each row execute function public.touch_updated_at();
create trigger invoices_touch    before update on invoices
  for each row execute function public.touch_updated_at();
create trigger notes_touch       before update on personal_notes
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------- column-level write guard
-- RLS is row-level: it cannot say "this user may update THIS column".
-- An apporteur owns his recommendation row, but must never move the pipeline,
-- set his own reward or archive it himself.
create or replace function public.guard_recommendation_columns()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- A null uid means there is no authenticated request: a migration, a seed,
  -- or an Edge Function on the service role. That is trusted server-side
  -- context, and it is safe to allow here because RLS has already run -- an
  -- anonymous caller never reaches this trigger, since no policy grants them
  -- the row in the first place (asserted in the test suite).
  if auth.uid() is null or is_admin(auth.uid()) then
    return new;
  end if;

  if new.current_stage_id  is distinct from old.current_stage_id
  or new.reward_amount     is distinct from old.reward_amount
  or new.reward_status     is distinct from old.reward_status
  or new.status            is distinct from old.status
  or new.assigned_admin_id is distinct from old.assigned_admin_id
  or new.parrain_id        is distinct from old.parrain_id
  or new.archived_at       is distinct from old.archived_at
  or new.deleted_at        is distinct from old.deleted_at then
    raise exception 'field reserved to an administrator' using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger recos_guard_columns before update on recommendations
  for each row execute function public.guard_recommendation_columns();

-- ------------------------------------------------------ invoice numbering
create or replace function public.assign_invoice_number()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year int := extract(year from coalesce(new.issued_on, current_date))::int;
begin
  new.sequence_year  := v_year;
  new.sequence_index := next_invoice_index(v_year);
  new.number         := format('FA-%s-%s', v_year, lpad(new.sequence_index::text, 4, '0'));
  return new;
end;
$$;

create trigger invoices_assign_number before insert on invoices
  for each row execute function public.assign_invoice_number();

-- --------------------------------------------------- invoice immutability
-- A signed invoice is a legal artefact: it is never edited and never deleted.
-- Corrections go through a credit note (avoir). Only the payment status may
-- still move.
create or replace function public.guard_invoice_immutability()
returns trigger
language plpgsql
as $$
begin
  if old.status in ('signed', 'paid', 'void') then
    if new.status is distinct from old.status
       and not (old.status = 'signed' and new.status in ('paid', 'void')) then
      raise exception 'invoice % is sealed: illegal status transition % -> %',
        old.number, old.status, new.status using errcode = '42501';
    end if;

    -- every other column must be identical
    if to_jsonb(new) - 'status' - 'updated_at' is distinct from
       to_jsonb(old) - 'status' - 'updated_at' then
      raise exception 'invoice % is sealed and cannot be modified', old.number
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

create trigger invoices_immutable before update on invoices
  for each row execute function public.guard_invoice_immutability();

create or replace function public.block_invoice_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception 'invoices are kept 10 years and cannot be deleted (use an avoir)'
    using errcode = '42501';
end;
$$;

create trigger invoices_no_delete before delete on invoices
  for each row execute function public.block_invoice_delete();

-- ------------------------------------------------------- seal on signature
-- Once both parties have signed, the invoice flips to 'signed' by itself.
create or replace function public.seal_invoice_when_fully_signed()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (select count(distinct signer_role) from invoice_signatures
       where invoice_id = new.invoice_id) = 2 then
    update invoices set status = 'signed'
     where id = new.invoice_id and status <> 'signed';

    update recommendations r
       set reward_status = 'invoiced'
      from invoices i
     where i.id = new.invoice_id
       and r.id = i.recommendation_id
       and r.reward_status = 'earned';
  end if;
  return new;
end;
$$;

create trigger invoice_signature_seals after insert on invoice_signatures
  for each row execute function public.seal_invoice_when_fully_signed();

-- ------------------------------------------- "Supprimer" must not hard-delete
-- The action sheet offers a red "Supprimer". Once an invoice exists, deleting
-- the recommendation would orphan a legal document, so it is refused and the
-- client must soft-delete instead.
create or replace function public.guard_recommendation_delete()
returns trigger
language plpgsql
as $$
begin
  if exists (select 1 from invoices where recommendation_id = old.id) then
    raise exception 'this recommendation carries an invoice: archive it instead of deleting'
      using errcode = '42501';
  end if;
  return old;
end;
$$;

create trigger recos_guard_delete before delete on recommendations
  for each row execute function public.guard_recommendation_delete();
