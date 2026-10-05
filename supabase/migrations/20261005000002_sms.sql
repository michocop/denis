-- Energy Courtage — a code by SMS: to prove a phone number, and to sign.
--
-- A signature was one tap in an app whose session might be anyone's: a
-- borrowed phone, an account left signed in. Now, once SMS is set up (the
-- send-sms function, sending through Brevo), an apporteur signs an invoice
-- only with a six-digit code sent to the mobile number they verified. The
-- code binds that one invoice, expires in ten minutes, allows five tries,
-- is used once, and is stored only as a hash. What was verified, and to
-- which number, is kept with the signature and printed on the PDF.
--
-- Until send-sms is configured, signing works as it did: the requirement
-- switches on with the hook (sms_signature_required), so a project without
-- an SMS account yet is not left unable to sign anything.

-- =============================================================== phones
-- E.164, or null for anything that is not a mobile number. French numbers
-- may be typed every usual way ("06 12 34 56 78", "+33 6…", "0033 6…");
-- other countries need their + prefix.
create or replace function public.normalise_mobile(p_phone text)
returns text
language plpgsql
immutable
as $$
declare v text := regexp_replace(coalesce(p_phone, ''), '[\s.\-()]', '', 'g');
begin
  if v ~ '^00' then v := '+' || substr(v, 3); end if;
  if v ~ '^0[67][0-9]{8}$' then v := '+33' || substr(v, 2); end if;
  if v ~ '^33[67][0-9]{8}$' then v := '+' || v; end if;
  if v ~ '^\+33' then
    return case when v ~ '^\+33[67][0-9]{8}$' then v end;   -- a French mobile
  end if;
  return case when v ~ '^\+[1-9][0-9]{7,14}$' then v end;
end;
$$;

-- "+33 6 •• •• •• 78": enough for the person to recognise their number, and
-- all that is shown or stored next to a signature.
create or replace function public.mask_phone(p_e164 text)
returns text
language sql
immutable
as $$
  select case
    when p_e164 ~ '^\+33[0-9]{9}$'
      then '+33 ' || substr(p_e164, 4, 1) || ' •• •• •• ' || right(p_e164, 2)
    when p_e164 is not null
      then left(p_e164, 3) || ' •••• ' || right(p_e164, 2)
  end;
$$;

alter table profiles add column phone_verified_at timestamptz;

-- A number is verified for as long as it is the number on file: changing it
-- takes the verification away, so a code can never go to an unproven phone.
create or replace function public.unverify_changed_phone()
returns trigger
language plpgsql
as $$
begin
  if new.phone is distinct from old.phone
     and new.phone_verified_at is not distinct from old.phone_verified_at then
    new.phone_verified_at := null;
  end if;
  return new;
end;
$$;

create trigger profiles_unverify_phone before update on profiles
  for each row execute function public.unverify_changed_phone();

-- phone_verified_at joins the columns only the server sets
create or replace function public.guard_profile_columns()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if is_admin(auth.uid()) then
    return new;
  end if;

  if new.id                      is distinct from old.id
  or new.role                    is distinct from old.role
  or new.status                  is distinct from old.status
  or new.email                   is distinct from old.email
  or new.vat_liable              is distinct from old.vat_liable
  or new.vat_number              is distinct from old.vat_number
  or new.kyc_state               is distinct from old.kyc_state
  or new.bank_details_on_file    is distinct from old.bank_details_on_file
  or new.bank_details_reference  is distinct from old.bank_details_reference
  or new.bank_details_updated_at is distinct from old.bank_details_updated_at
  or new.created_at              is distinct from old.created_at
  or (new.phone_verified_at is distinct from old.phone_verified_at
      and new.phone_verified_at is not null) then
    raise exception 'field reserved to an administrator' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- ================================================================ codes
create table sms_codes (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references profiles(id) on delete cascade,
  purpose     text not null check (purpose in ('verify_phone', 'sign_invoice')),
  phone       text not null,          -- E.164, where the code was sent
  invoice_id  uuid references invoices(id),
  code_hash   text not null,          -- sha256(code:id); the code itself is never stored
  attempts    int  not null default 0,
  expires_at  timestamptz not null,
  verified_at timestamptz,            -- the right code came back
  consumed_at timestamptz,            -- and was used (or replaced)
  created_at  timestamptz not null default clock_timestamp()
);
create index sms_codes_lookup_idx on sms_codes (profile_id, purpose, created_at desc);

-- read and written only by the functions below
alter table sms_codes enable row level security;
revoke all on sms_codes from authenticated, anon;

-- SMS is required once there is something to send it: the send-sms hook.
create or replace function public.sms_signature_required()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from edge_hooks where name = 'send-sms' and enabled);
$$;

-- Sends a code. For a signature: to the caller's verified number, bound to
-- that invoice. For a number being verified: to that number.
create or replace function public.request_sms_code(
  p_purpose    text,
  p_invoice_id uuid default null,
  p_phone      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  v_prof  profiles%rowtype;
  v_inv   invoices%rowtype;
  v_phone text;
  v_code  text;
  v_id    uuid := gen_random_uuid();
  v_text  text;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select * into v_prof from profiles where id = v_uid;
  if not found or v_prof.status <> 'active' then
    raise exception 'only an active member can receive a code' using errcode = '42501';
  end if;

  if p_purpose = 'sign_invoice' then
    select * into v_inv from invoices where id = p_invoice_id;
    if not found or v_inv.apporteur_id is distinct from v_uid then
      raise exception 'invoice not found' using errcode = 'P0002';
    end if;
    if v_inv.status not in ('draft', 'awaiting_signatures') then
      raise exception 'Cette facture ne peut plus être signée.' using errcode = '42501';
    end if;
    -- nothing to send: the signature goes ahead without a code
    if not sms_signature_required() then
      return jsonb_build_object('required', false);
    end if;
    if v_prof.phone_verified_at is null or normalise_mobile(v_prof.phone) is null then
      raise exception 'Vérifiez d''abord votre numéro de mobile.' using errcode = 'P0001',
        hint = 'phone_not_verified';
    end if;
    v_phone := normalise_mobile(v_prof.phone);
  elsif p_purpose = 'verify_phone' then
    if not sms_signature_required() then
      raise exception 'L''envoi de SMS n''est pas encore configuré.' using errcode = 'P0001';
    end if;
    v_phone := normalise_mobile(p_phone);
    if v_phone is null then
      raise exception 'Ce numéro de mobile n''est pas valide.' using errcode = '22023';
    end if;
  else
    raise exception 'unknown purpose' using errcode = '22023';
  end if;

  -- a code costs money and is a way in: one every half-minute is someone
  -- typing, dozens an hour is someone trying
  if exists (select 1 from sms_codes
              where profile_id = v_uid and created_at > now() - interval '30 seconds') then
    raise exception 'Patientez quelques secondes avant de demander un nouveau code.'
      using errcode = 'P0001', hint = 'too_soon';
  end if;
  if (select count(*) from sms_codes
       where profile_id = v_uid and created_at > now() - interval '1 hour') >= 6 then
    raise exception 'Trop de codes demandés. Réessayez dans une heure.'
      using errcode = 'P0001', hint = 'too_many';
  end if;

  -- uniform over 000000–999999: 2^32 mod 10^6 is a bias of under 0.03 %
  v_code := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint
                   & 4294967295) % 1000000)::text, 6, '0');

  -- one live code per purpose (and invoice): asking again retires the last
  update sms_codes set consumed_at = now()
   where profile_id = v_uid and purpose = p_purpose and consumed_at is null
     and invoice_id is not distinct from p_invoice_id;

  insert into sms_codes (id, profile_id, purpose, phone, invoice_id, code_hash, expires_at)
  values (v_id, v_uid, p_purpose, v_phone, p_invoice_id,
          encode(digest(v_code || ':' || v_id::text, 'sha256'), 'hex'),
          now() + interval '10 minutes');

  v_text := case p_purpose
    when 'sign_invoice' then
      'Trinity Énergie : ' || v_code || ' est votre code pour signer la facture '
      || v_inv.number || '. Il expire dans 10 minutes. Ne le communiquez à personne.'
    else
      'Trinity Énergie : ' || v_code || ' est votre code de vérification. '
      || 'Il expire dans 10 minutes.'
  end;

  if not call_edge_hook('send-sms', jsonb_build_object('to', v_phone, 'text', v_text,
                                                       'sms_code_id', v_id)) then
    raise exception 'Le SMS n''a pas pu être envoyé. Réessayez.' using errcode = 'P0001';
  end if;

  return jsonb_build_object('required', true, 'masked_phone', mask_phone(v_phone),
                            'expires_at', now() + interval '10 minutes');
end;
$$;

-- Checks a code. It answers rather than raises, because a wrong code has to
-- stay counted, and a raise would roll the count back with it. Five wrong
-- codes retire the code.
--   verify_phone: the right code makes the number the verified one.
--   sign_invoice: the right code is held, for ten minutes, for the signature
--                 on that invoice, which uses it up (guard_invoice_signature).
create or replace function public.confirm_sms_code(
  p_purpose    text,
  p_code       text,
  p_invoice_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_row sms_codes%rowtype;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into v_row from sms_codes
   where profile_id = v_uid and purpose = p_purpose
     and consumed_at is null and verified_at is null
     and invoice_id is not distinct from p_invoice_id
   order by created_at desc
   limit 1
   for update;

  if not found or v_row.expires_at < now() then
    return jsonb_build_object('ok', false, 'reason', 'expired',
                              'message', 'Ce code a expiré. Demandez-en un nouveau.');
  end if;
  if v_row.attempts >= 5 then
    return jsonb_build_object('ok', false, 'reason', 'locked',
                              'message', 'Trop d''essais. Demandez un nouveau code.');
  end if;

  if encode(digest(regexp_replace(coalesce(p_code, ''), '\s', '', 'g') || ':' || v_row.id::text,
                   'sha256'), 'hex') is distinct from v_row.code_hash then
    update sms_codes set attempts = attempts + 1 where id = v_row.id;
    return jsonb_build_object('ok', false,
      'reason',  case when v_row.attempts + 1 >= 5 then 'locked' else 'wrong' end,
      'message', case when v_row.attempts + 1 >= 5
                      then 'Trop d''essais. Demandez un nouveau code.'
                      else 'Code incorrect.' end,
      'attempts_left', greatest(0, 4 - v_row.attempts));
  end if;

  if p_purpose = 'verify_phone' then
    update sms_codes set verified_at = now(), consumed_at = now() where id = v_row.id;
    update profiles set phone = v_row.phone, phone_verified_at = now() where id = v_uid;
    insert into audit_log (actor_id, entity, entity_id, action, after)
    values (v_uid, 'profiles', v_uid, 'verify_phone',
            jsonb_build_object('phone', mask_phone(v_row.phone)));
  else
    update sms_codes set verified_at = now() where id = v_row.id;
  end if;

  return jsonb_build_object('ok', true, 'masked_phone', mask_phone(v_row.phone));
end;
$$;

-- =========================================================== signatures
alter table invoice_signatures add column otp_phone text;

-- The table itself refuses an apporteur signature without a confirmed code,
-- so neither sign_invoice() nor an insert of the row can step around it.
-- The company signs from an admin's own session and needs none.
create or replace function public.guard_invoice_signature()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inv  invoices%rowtype;
  v_ip   text;
  v_code sms_codes%rowtype;
begin
  -- The lock serialises two parties signing at the same moment, so the second
  -- sees the first. Without it each could count one signature, and the
  -- invoice would never seal.
  select * into v_inv from invoices where id = new.invoice_id for update;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;

  if auth.uid() is not null
     and (new.signer_id is distinct from auth.uid()
          or not (v_inv.apporteur_id = new.signer_id or is_admin(new.signer_id))) then
    raise exception 'you are not a party to this invoice' using errcode = '42501';
  end if;

  if v_inv.status not in ('draft', 'awaiting_signatures') then
    raise exception 'invoice % cannot be signed: it is %', v_inv.number, v_inv.status
      using errcode = '42501';
  end if;

  if new.document_sha256 is distinct from v_inv.document_sha256 then
    raise exception 'the document being signed does not match the issued invoice'
      using errcode = '22023';
  end if;

  new.otp_verified := false;
  new.otp_phone := null;
  if new.signer_role = 'apporteur' and sms_signature_required() then
    select * into v_code from sms_codes
     where profile_id = new.signer_id and purpose = 'sign_invoice'
       and invoice_id = new.invoice_id
       and verified_at > now() - interval '10 minutes' and consumed_at is null
     order by verified_at desc
     limit 1
     for update;
    if not found then
      raise exception 'Un code SMS est nécessaire pour signer.' using errcode = '42501',
        hint = 'sms_required';
    end if;
    update sms_codes set consumed_at = now() where id = v_code.id;
    new.otp_verified := true;
    new.otp_phone := mask_phone(v_code.phone);
  end if;

  select first_name || ' ' || last_name into new.signer_full_name
    from profiles where id = new.signer_id;
  new.signed_at := now();

  -- the first address in X-Forwarded-For is the client's, as the gateway saw it
  v_ip := btrim(split_part(coalesce(request_header('x-forwarded-for'),
                                    request_header('x-real-ip'), ''), ',', 1));
  if v_ip <> '' then
    begin
      new.ip_address := v_ip::inet;
    exception when others then
      null;   -- an unparseable header is not worth refusing a signature over
    end;
  end if;
  new.user_agent := coalesce(request_header('user-agent'), new.user_agent);
  return new;
end;
$$;

-- ====================================================== on the document
-- Each signature says whether it was confirmed by SMS, and to which number:
-- what makes it worth something if it is ever disputed.
create or replace function public.invoice_document(p_invoice_id uuid)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'number', i.number,
    'kind', case when i.corrects_invoice_id is null then 'invoice' else 'credit_note' end,
    'corrects_number', (select o.number from invoices o where o.id = i.corrects_invoice_id),
    'document_sha256', i.document_sha256,
    'pdf_path', i.pdf_path,
    'corrects_invoice_id', i.corrects_invoice_id,
    'issuer', jsonb_build_object(
      'name',        (i.issuer_snapshot ->> 'first_name') || ' ' || (i.issuer_snapshot ->> 'last_name'),
      'company',     i.issuer_snapshot ->> 'company_name',
      'city',        i.issuer_snapshot ->> 'city',
      'siret',       i.issuer_snapshot ->> 'siret',
      'address',     i.issuer_snapshot ->> 'address',
      'postal_code', i.issuer_snapshot ->> 'postal_code',
      'vat_number',  i.issuer_snapshot ->> 'vat_number'
    ),
    'customer', i.customer_snapshot,
    'apporteur', jsonb_build_object(
      'name',        (i.apporteur_snapshot ->> 'first_name') || ' ' || (i.apporteur_snapshot ->> 'last_name'),
      'company',     i.apporteur_snapshot ->> 'company_name',
      'siret',       i.apporteur_snapshot ->> 'siret',
      'legal_form',  i.apporteur_snapshot ->> 'legal_form',
      'address',     i.apporteur_snapshot ->> 'address',
      'postal_code', i.apporteur_snapshot ->> 'postal_code',
      'city',        i.apporteur_snapshot ->> 'city',
      'vat_number',  i.apporteur_snapshot ->> 'vat_number'
    ),
    'attestation', jsonb_build_object(
      'soussigne',       (i.apporteur_snapshot ->> 'first_name') || ' ' || (i.apporteur_snapshot ->> 'last_name'),
      'mis_en_relation', coalesce(i.customer_snapshot ->> 'legal_name',
                                  i.issuer_snapshot ->> 'company_name'),
      'avec',            i.filleul_name,
      'prestation',      i.prestation_label,
      'intervenue_le',   to_char(i.intervened_on, 'DD.MM.YYYY')
    ),
    'amount', jsonb_build_object(
      'ht',       to_char(i.amount_ht, 'FM999999990.00'),
      'vat_rate', i.vat_rate,
      'vat',      to_char(i.vat_amount, 'FM999999990.00'),
      'ttc',      to_char(i.amount_ttc, 'FM999999990.00'),
      'currency', i.currency
    ),
    'legal_mentions',       i.legal_mentions,
    'payment_method',       i.payment_method,
    'place',                i.place,
    'issued_on',            to_char(i.issued_on, 'DD.MM.YYYY'),
    'due_on',               to_char(i.due_on, 'DD.MM.YYYY'),
    'self_billing_mention', i.self_billing_mention,
    'late_payment_mention', i.late_payment_mention,
    'tax_notice',           i.tax_notice,
    'status',               i.status,
    'signatures', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'role',      expected.role,
               'name',      coalesce(s.signer_full_name,
                              case expected.role
                                when 'apporteur' then
                                  (i.apporteur_snapshot ->> 'first_name') || ' ' || (i.apporteur_snapshot ->> 'last_name')
                                else
                                  (i.issuer_snapshot ->> 'first_name') || ' ' || (i.issuer_snapshot ->> 'last_name')
                              end),
               'signed',       s.id is not null,
               'signed_at',    s.signed_at,
               'sms_verified', coalesce(s.otp_verified, false),
               'sms_phone',    s.otp_phone
             ) order by expected.ord), '[]'::jsonb)
      from (values ('apporteur'::signature_role, 1), ('entreprise'::signature_role, 2))
           as expected(role, ord)
      left join invoice_signatures s
             on s.invoice_id = i.id and s.signer_role = expected.role
    )
  )
  from invoices i
  where i.id = p_invoice_id;
$$;

-- What the app needs to know before it offers "Signer".
create or replace function public.my_sms_status()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'sms_required', sms_signature_required(),
    'phone_verified', p.phone_verified_at is not null and normalise_mobile(p.phone) is not null,
    'masked_phone', mask_phone(normalise_mobile(p.phone)))
  from profiles p where p.id = auth.uid();
$$;

-- ============================================================== grants
revoke execute on function public.request_sms_code(text, uuid, text) from public, anon;
revoke execute on function public.confirm_sms_code(text, text, uuid) from public, anon;
revoke execute on function public.my_sms_status() from public, anon;
revoke execute on function public.sms_signature_required() from public, anon;
revoke execute on function public.normalise_mobile(text) from public, anon;
revoke execute on function public.mask_phone(text) from public, anon;
grant execute on function public.request_sms_code(text, uuid, text) to authenticated, service_role;
grant execute on function public.confirm_sms_code(text, text, uuid) to authenticated, service_role;
grant execute on function public.my_sms_status() to authenticated, service_role;
grant execute on function public.sms_signature_required() to authenticated, service_role;
grant execute on function public.normalise_mobile(text) to authenticated, service_role;
grant execute on function public.mask_phone(text) to authenticated, service_role;
