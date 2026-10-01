-- Energy Courtage — which channel a signature code goes on.
--
-- SMS, by decision: every phone receives it and iOS fills the code in by
-- itself. WhatsApp is about a cent cheaper per code in France but needs the
-- app installed and a Meta-approved template, so it stays available as a
-- switch (update sms_config set channel = 'whatsapp') rather than the default.
-- A signer may also ask for a given channel (p_channel); the sender falls back
-- to SMS on its own when WhatsApp refuses a number (supabase/functions/send-sms).

alter table sms_config
  add column channel text not null default 'sms'
    constraint sms_config_channel check (channel in ('whatsapp', 'sms'));

drop function if exists public.request_signature_otp(uuid);

create or replace function public.request_signature_otp(
  p_invoice_id uuid,
  p_channel    text default null
)
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
  v_channel text;
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

  -- the configured channel, unless the caller asked for a specific one
  v_channel := coalesce(nullif(lower(btrim(p_channel)), ''), v_config.channel);
  if v_channel not in ('whatsapp', 'sms') then
    raise exception 'unknown channel %', p_channel using errcode = '22023';
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
                   'to',      v_phone,
                   'code',    v_code,
                   'channel', v_channel,
                   'body', 'Trinity Énergie : votre code de signature est ' || v_code
                           || '. Il expire dans 10 minutes. Ne le communiquez à personne.')
    );
  exception when others then
    raise exception 'Le code n''a pas pu être envoyé. Réessayez dans un instant.'
      using errcode = '58000';
  end;

  return jsonb_build_object(
    'required',   true,
    'channel',    v_channel,
    'sent_to',    phone_masked(v_phone),
    'expires_at', v_otp.expires_at
  );
end;
$$;


revoke all on function public.request_signature_otp(uuid, text) from public, anon;
grant execute on function public.request_signature_otp(uuid, text) to authenticated;
