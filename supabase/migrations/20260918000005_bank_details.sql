-- Energy Courtage — stop pretending to encrypt bank details.
--
-- profiles.iban_encrypted was a column whose NAME claimed protection that no
-- code provided: nothing ever encrypted it, and nothing decrypted it. A
-- plaintext IBAN under a reassuring name is worse than an honest one, because
-- the name stops anyone asking the question.
--
-- Real protection needs the key OUTSIDE the database -- a KMS or Supabase
-- Vault -- otherwise a dump contains both halves and the encryption is
-- decoration. Rather than ship decoration, the app stops holding IBANs at all.
-- It only ever needed to know whether an apporteur CAN be paid, which is a
-- boolean; the account details themselves live where the transfer is actually
-- made, in the client's banking or accounting system.
--
-- If holding them in-app is later required, the honest path is Supabase Vault
-- with the key managed outside Postgres, plus an admin-only accessor -- not a
-- column with a hopeful name.

-- the payables view reads the column, so it goes first and is rebuilt below
drop view if exists payable_invoices;
alter table profiles drop column if exists iban_encrypted;

alter table profiles
  add column bank_details_on_file boolean not null default false,
  add column bank_details_updated_at timestamptz,
  add column bank_details_reference text;   -- e.g. the accounting system's id

comment on column profiles.bank_details_on_file is
  'Whether payment details are held in the client''s own banking system. The '
  'account number itself is deliberately not stored here.';

create or replace function public.set_bank_details_on_file(
  p_profile_id uuid,
  p_on_file    boolean,
  p_reference  text default null
)
returns profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile profiles%rowtype;
begin
  if not is_admin(auth.uid()) then
    raise exception 'only an admin records payment details' using errcode = '42501';
  end if;

  update profiles
     set bank_details_on_file = p_on_file,
         bank_details_updated_at = now(),
         bank_details_reference = p_reference
   where id = p_profile_id
  returning * into v_profile;

  if not found then
    raise exception 'no such member' using errcode = 'P0002';
  end if;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (auth.uid(), 'profiles', p_profile_id, 'set_bank_details',
          jsonb_build_object('on_file', p_on_file));
  return v_profile;
end;
$$;

-- the payables list asks the same question, of the new column
create view payable_invoices with (security_invoker = true) as
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
where i.status = 'signed';

grant select on payable_invoices to authenticated;

-- account deletion no longer has an IBAN to clear
create or replace function public.request_account_deletion()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  update profiles
     set status = 'suspended',
         phone = null, avatar_url = null,
         bank_details_on_file = false, bank_details_reference = null,
         address = null, postal_code = null,
         email = 'deleted+' || id::text || '@invalid'
   where id = v_uid;

  insert into audit_log (actor_id, entity, entity_id, action)
  values (v_uid, 'profiles', v_uid, 'account_deletion_requested');
end;
$$;
