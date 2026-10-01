-- Energy Courtage — a code by SMS before signing.
--
-- The evidence bundle has carried `otp_verified` since the first migration,
-- and it has always been false: nothing sent a code. This sends one, checks
-- it, and makes the signature depend on it.
--
-- The flow is three calls, not one, on purpose:
--   1. request_signature_otp(invoice)   -> a code goes out by SMS
--   2. verify_signature_otp(invoice, code) -> right / wrong / expired / locked
--   3. sign_invoice(invoice, digest)    -> consumes the verified code
-- A wrong code has to *count*. If checking it happened inside sign_invoice,
-- the failure would raise, the transaction would roll back, and the attempt
-- counter would roll back with it: a script could guess forever. Verifying is
-- therefore its own call that commits whatever it learned.
--
-- Like push, SMS ships INERT. Until a row exists in sms_config no code is
-- asked for and signing behaves exactly as before, with otp_verified = false
-- recorded honestly. Configuring the sender is what switches the requirement
-- on, so a project can never demand a code it has no way to deliver.

-- ---------------------------------------------------------------- settings
create table sms_config (
  id            boolean primary key default true,
  function_url  text not null,
  hook_secret   text not null,
  enabled       boolean not null default true,
  updated_at    timestamptz not null default now(),
  constraint sms_config_singleton check (id)
);

alter table sms_config enable row level security;
-- No policy: the secret would let its holder send texts on the company's bill.
comment on table sms_config is
  'Read only by SECURITY DEFINER functions. Never exposed to the client.';

create or replace function public.signature_otp_required()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from sms_config where enabled);
$$;

-- -------------------------------------------------------------- the codes
-- Only a hash is kept. Whoever can read this table (a backup, a console
-- session) still cannot sign in somebody else's name with it.
create table signature_otps (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references invoices(id) on delete cascade,
  profile_id  uuid not null references profiles(id) on delete cascade,
  code_sha256 text not null,
  phone       text not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '10 minutes',
  attempts    int not null default 0,
  verified_at timestamptz,
  consumed_at timestamptz
);

create index signature_otps_lookup_idx
  on signature_otps (profile_id, invoice_id, created_at desc);

alter table signature_otps enable row level security;
-- No policy, no grant: only the functions below touch it.

-- 06 12 34 56 78, 0612345678, +33 6 12 34 56 78, 0033612345678 -> +33612345678
create or replace function public.phone_e164(p_phone text)
returns text
language sql
immutable
as $$
  with d as (
    select case
             when btrim(coalesce(p_phone, '')) like '+%'
               then '+' || regexp_replace(p_phone, '\D', '', 'g')
             when regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') like '00%'
               then '+' || substr(regexp_replace(p_phone, '\D', '', 'g'), 3)
             when regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') ~ '^0[1-9][0-9]{8}$'
               then '+33' || substr(regexp_replace(p_phone, '\D', '', 'g'), 2)
           end as n
  )
  select case when n ~ '^\+[1-9][0-9]{7,14}$' then n end from d;
$$;

-- What the app shows: "un code a été envoyé au 06 •• •• •• 78".
create or replace function public.phone_masked(p_e164 text)
returns text
language sql
immutable
as $$
  select case
           when p_e164 like '+33%' and length(p_e164) = 12
             then '0' || substr(p_e164, 4, 1) || ' •• •• •• ' || right(p_e164, 2)
           else '•• ' || right(p_e164, 2)
         end;
$$;

-- Who may sign this invoice, and in which capacity. One definition, used by
-- every function here, so the three calls cannot disagree.
create or replace function public.invoice_signer_role(p_invoice_id uuid, p_uid uuid)
returns signature_role
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare v_inv invoices%rowtype;
begin
  select * into v_inv from invoices where id = p_invoice_id;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  if v_inv.apporteur_id = p_uid then
    return 'apporteur';
  elsif is_admin(p_uid) then
    return 'entreprise';
  end if;
  raise exception 'you are not a party to this invoice' using errcode = '42501';
end;
$$;

-- ---------------------------------------------------------------- step 1
create or replace function public.request_signature_otp(p_invoice_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_role   signature_role;
  v_config sms_config%rowtype;
  v_phone  text;
  v_code   text;
  v_otp    signature_otps%rowtype;
  v_recent int;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  v_role := invoice_signer_role(p_invoice_id, v_uid);

  if exists (select 1 from invoice_signatures
              where invoice_id = p_invoice_id and signer_role = v_role) then
    raise exception 'this invoice is already signed on your side' using errcode = '23505';
  end if;

  select * into v_config from sms_config where enabled;
  if not found then
    -- SMS is not set up: the app goes straight to signing.
    return jsonb_build_object('required', false);
  end if;

  select phone_e164(phone) into v_phone from profiles where id = v_uid;
  if v_phone is null then
    raise exception 'Ajoutez un numéro de mobile valide dans votre profil pour recevoir le code de signature.'
      using errcode = '22023';
  end if;

  -- One code a minute, five an hour: enough for a typo or a dead zone, not
  -- enough to run up the bill or to spray texts at somebody.
  if exists (select 1 from signature_otps
              where profile_id = v_uid and created_at > now() - interval '60 seconds') then
    raise exception 'Un code vient d''être envoyé. Patientez une minute avant d''en demander un autre.'
      using errcode = '54000';
  end if;
  select count(*) into v_recent from signature_otps
   where profile_id = v_uid and created_at > now() - interval '1 hour';
  if v_recent >= 5 then
    raise exception 'Trop de codes demandés. Réessayez dans une heure.'
      using errcode = '54000';
  end if;

  -- a new code replaces any earlier one still pending for this invoice
  update signature_otps set expires_at = least(expires_at, now())
   where profile_id = v_uid and invoice_id = p_invoice_id and consumed_at is null;

  -- 6 digits from the CSPRNG; the modulo bias over 2^32 is negligible
  v_code := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');

  insert into signature_otps (invoice_id, profile_id, code_sha256, phone)
  values (p_invoice_id, v_uid, '', v_phone)
  returning * into v_otp;
  -- salted with the row id, so equal codes never share a hash
  update signature_otps
     set code_sha256 = encode(digest(v_otp.id::text || ':' || v_code, 'sha256'), 'hex')
   where id = v_otp.id;

  begin
    perform net.http_post(
      url     := v_config.function_url,
      headers := jsonb_build_object('Content-Type', 'application/json',
                                    'x-hook-secret', v_config.hook_secret),
      body    := jsonb_build_object(
                   'to',   v_phone,
                   'code', v_code,
                   'body', 'Trinity Énergie : votre code de signature est ' || v_code
                           || '. Il expire dans 10 minutes. Ne le communiquez à personne.')
    );
  exception when others then
    raise exception 'Le code n''a pas pu être envoyé. Réessayez dans un instant.'
      using errcode = '58000';
  end;

  return jsonb_build_object(
    'required',   true,
    'sent_to',    phone_masked(v_phone),
    'expires_at', v_otp.expires_at
  );
end;
$$;

-- ---------------------------------------------------------------- step 2
-- Never raises for a wrong code: it returns, so the attempt it counted is
-- committed. Results: verified | wrong | expired | locked | none.
create or replace function public.verify_signature_otp(p_invoice_id uuid, p_code text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_otp signature_otps%rowtype;
  c_max_attempts constant int := 5;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  perform invoice_signer_role(p_invoice_id, v_uid);

  select * into v_otp from signature_otps
   where profile_id = v_uid and invoice_id = p_invoice_id and consumed_at is null
   order by created_at desc
   limit 1
   for update;

  if not found then
    return jsonb_build_object('result', 'none');
  end if;
  if v_otp.verified_at is not null then
    return jsonb_build_object('result', 'verified');
  end if;
  if v_otp.attempts >= c_max_attempts then
    return jsonb_build_object('result', 'locked');
  end if;
  if v_otp.expires_at <= now() then
    return jsonb_build_object('result', 'expired');
  end if;

  if v_otp.code_sha256 = encode(digest(v_otp.id::text || ':' || regexp_replace(coalesce(p_code, ''), '\D', '', 'g'), 'sha256'), 'hex') then
    update signature_otps set verified_at = now(), attempts = attempts + 1 where id = v_otp.id;
    return jsonb_build_object('result', 'verified');
  end if;

  update signature_otps set attempts = attempts + 1 where id = v_otp.id;
  if v_otp.attempts + 1 >= c_max_attempts then
    return jsonb_build_object('result', 'locked');
  end if;
  return jsonb_build_object('result', 'wrong',
                            'remaining', c_max_attempts - v_otp.attempts - 1);
end;
$$;

-- ---------------------------------------------------------------- step 3
-- Signing used to rely on the insert policy for who may sign. It now runs as
-- the definer, because the policy let the client write otp_verified = true
-- itself; the checks the policy made are repeated here, explicitly.
drop function if exists public.sign_invoice(uuid, text, inet, text);

create or replace function public.sign_invoice(
  p_invoice_id      uuid,
  p_document_sha256 text,
  p_ip              inet default null,
  p_user_agent      text default null
)
returns invoice_signatures
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid  uuid := auth.uid();
  v_inv  invoices%rowtype;
  v_role signature_role;
  v_name text;
  v_otp  uuid;
  v_sig  invoice_signatures%rowtype;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  v_role := invoice_signer_role(p_invoice_id, v_uid);
  select * into v_inv from invoices where id = p_invoice_id;

  -- what is signed must be the document the server issued
  if v_inv.document_sha256 is distinct from p_document_sha256 then
    raise exception 'the document being signed does not match the issued invoice'
      using errcode = '22023';
  end if;

  if signature_otp_required() then
    select id into v_otp from signature_otps
     where profile_id = v_uid and invoice_id = p_invoice_id
       and verified_at is not null and consumed_at is null
       and verified_at > now() - interval '15 minutes'
     order by verified_at desc
     limit 1
     for update;
    if v_otp is null then
      raise exception 'Confirmez d''abord le code reçu par SMS.' using errcode = '28000';
    end if;
    update signature_otps set consumed_at = now() where id = v_otp;
  end if;

  select first_name || ' ' || last_name into v_name from profiles where id = v_uid;

  insert into invoice_signatures (invoice_id, signer_id, signer_role, signer_full_name,
                                  document_sha256, ip_address, user_agent, otp_verified)
  values (p_invoice_id, v_uid, v_role, v_name, p_document_sha256, p_ip, p_user_agent,
          v_otp is not null)
  returning * into v_sig;

  return v_sig;
end;
$$;

-- The only way in is sign_invoice now. Leaving the policy would let a client
-- skip the code by inserting the row itself, with otp_verified = true.
drop policy if exists signature_insert on invoice_signatures;
revoke insert on invoice_signatures from authenticated;

revoke all on function public.request_signature_otp(uuid) from public, anon;
revoke all on function public.verify_signature_otp(uuid, text) from public, anon;
revoke all on function public.sign_invoice(uuid, text, inet, text) from public, anon;
revoke all on function public.invoice_signer_role(uuid, uuid) from public, anon, authenticated;
grant execute on function public.request_signature_otp(uuid) to authenticated;
grant execute on function public.verify_signature_otp(uuid, text) to authenticated;
grant execute on function public.sign_invoice(uuid, text, inet, text) to authenticated;
grant execute on function public.signature_otp_required() to authenticated;
