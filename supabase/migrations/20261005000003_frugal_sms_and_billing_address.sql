-- Energy Courtage — fewer SMS, and no invoice without an address.
--
-- Every SMS is paid for. Three were being sent where one would do:
--   * an apporteur's first signature took two codes: one to prove the number,
--     one to sign. The signing code now does both: it goes to the number
--     typed, and coming back proves it.
--   * signing three invoices took three codes. A confirmed code now opens a
--     ten-minute signing window, kept with each signature it covers.
--   * leaving the code screen and coming back sent another code although the
--     last one was still good. It is reused unless a new one is asked for.
-- The texts are also kept to one SMS: GSM-7 characters only, at most 160.
--
-- And an invoice is refused while the apporteur's billing address is
-- incomplete: the address of both parties is a mandatory mention
-- (CGI ann. II art. 242 nonies A), and an invoice issued without it would be
-- sealed without it forever.

-- ================================================================= texts
-- Only characters of the GSM 03.38 basic set, so each text is one SMS of up
-- to 160 characters; a single "ê" would make it UCS-2, 70 characters a part.
create or replace function public.sms_text(p_purpose text, p_code text)
returns text
language sql
immutable
as $$
  select case p_purpose
    when 'sign_invoice' then
      'Trinity Énergie : ' || p_code || ' est votre code de signature. '
      || 'Valable 10 minutes. Ne le communiquez à personne.'
    else
      'Trinity Énergie : ' || p_code || ' est votre code de vérification. '
      || 'Valable 10 minutes.'
  end;
$$;

-- ================================================================ asking
drop function if exists public.request_sms_code(text, uuid, text);

create or replace function public.request_sms_code(
  p_purpose    text,
  p_invoice_id uuid default null,
  p_phone      text default null,
  p_resend     boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid     uuid := auth.uid();
  v_prof    profiles%rowtype;
  v_inv     invoices%rowtype;
  v_phone   text;
  v_code    text;
  v_id      uuid := gen_random_uuid();
  v_live    sms_codes%rowtype;
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
    if not sms_signature_required() then
      return jsonb_build_object('required', false);
    end if;

    -- a code confirmed in the last ten minutes still covers this signature
    select * into v_live from sms_codes
     where profile_id = v_uid and purpose = 'sign_invoice' and consumed_at is null
       and verified_at > now() - interval '10 minutes'
     order by verified_at desc limit 1;
    if found then
      return jsonb_build_object('required', false, 'session', true,
                                'masked_phone', mask_phone(v_live.phone));
    end if;

    -- the number typed, which the code will prove; else the verified one
    if p_phone is not null then
      v_phone := normalise_mobile(p_phone);
      if v_phone is null then
        raise exception 'Ce numéro de mobile n''est pas valide.' using errcode = '22023';
      end if;
    elsif v_prof.phone_verified_at is not null and normalise_mobile(v_prof.phone) is not null then
      v_phone := normalise_mobile(v_prof.phone);
    else
      raise exception 'Indiquez votre numéro de mobile.' using errcode = 'P0001',
        hint = 'phone_not_verified';
    end if;
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

  -- the code already on its way is still good: no second SMS for it
  if not p_resend then
    select * into v_live from sms_codes
     where profile_id = v_uid and purpose = p_purpose and phone = v_phone
       and consumed_at is null and verified_at is null
       and attempts < 5 and expires_at > now() + interval '1 minute'
     order by created_at desc limit 1;
    if found then
      return jsonb_build_object('required', true, 'reused', true,
                                'masked_phone', mask_phone(v_phone),
                                'expires_at', v_live.expires_at);
    end if;
  end if;

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

  v_code := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint
                   & 4294967295) % 1000000)::text, 6, '0');

  -- one live code per purpose: asking again retires the last
  update sms_codes set consumed_at = now()
   where profile_id = v_uid and purpose = p_purpose and consumed_at is null
     and verified_at is null;

  insert into sms_codes (id, profile_id, purpose, phone, invoice_id, code_hash, expires_at)
  values (v_id, v_uid, p_purpose, v_phone, p_invoice_id,
          encode(digest(v_code || ':' || v_id::text, 'sha256'), 'hex'),
          now() + interval '10 minutes');

  if not call_edge_hook('send-sms', jsonb_build_object(
           'to', v_phone, 'text', sms_text(p_purpose, v_code), 'sms_code_id', v_id)) then
    raise exception 'Le SMS n''a pas pu être envoyé. Réessayez.' using errcode = 'P0001';
  end if;

  return jsonb_build_object('required', true, 'masked_phone', mask_phone(v_phone),
                            'expires_at', now() + interval '10 minutes');
end;
$$;

-- ============================================================ confirming
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
  v_uid  uuid := auth.uid();
  v_row  sms_codes%rowtype;
  v_prof profiles%rowtype;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- for a signature, whichever invoice the code was asked from: the window
  -- it opens covers the apporteur's signatures, not one document
  select * into v_row from sms_codes
   where profile_id = v_uid and purpose = p_purpose
     and consumed_at is null and verified_at is null
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

  update sms_codes
     set verified_at = now(),
         consumed_at = case when p_purpose = 'verify_phone' then now() end
   where id = v_row.id;

  -- either purpose proves the number the code went to
  select * into v_prof from profiles where id = v_uid;
  if v_prof.phone_verified_at is null or normalise_mobile(v_prof.phone) is distinct from v_row.phone then
    update profiles set phone = v_row.phone, phone_verified_at = now() where id = v_uid;
    insert into audit_log (actor_id, entity, entity_id, action, after)
    values (v_uid, 'profiles', v_uid, 'verify_phone',
            jsonb_build_object('phone', mask_phone(v_row.phone), 'via', p_purpose));
  end if;

  return jsonb_build_object('ok', true, 'masked_phone', mask_phone(v_row.phone),
    'valid_until', case when p_purpose = 'sign_invoice' then now() + interval '10 minutes' end);
end;
$$;

-- =========================================================== signatures
-- The window, not one invoice: a code confirmed in the last ten minutes, and
-- not retired by a newer request, covers each apporteur signature in it.
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
       and verified_at > now() - interval '10 minutes' and consumed_at is null
     order by verified_at desc
     limit 1;
    if not found then
      raise exception 'Un code SMS est nécessaire pour signer.' using errcode = '42501',
        hint = 'sms_required';
    end if;
    new.otp_verified := true;
    new.otp_phone := mask_phone(v_code.phone);
  end if;

  select first_name || ' ' || last_name into new.signer_full_name
    from profiles where id = new.signer_id;
  new.signed_at := now();

  v_ip := btrim(split_part(coalesce(request_header('x-forwarded-for'),
                                    request_header('x-real-ip'), ''), ',', 1));
  if v_ip <> '' then
    begin
      new.ip_address := v_ip::inet;
    exception when others then
      null;
    end;
  end if;
  new.user_agent := coalesce(request_header('user-agent'), new.user_agent);
  return new;
end;
$$;

-- ======================================================== the address
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
  v_uid       uuid := auth.uid();
  v_reco      recommendations%rowtype;
  v_issuer    profiles%rowtype;
  v_apporteur profiles%rowtype;
  v_inv       invoices%rowtype;
begin
  if not is_admin(v_uid) then
    raise exception 'only an administrator issues an invoice' using errcode = '42501';
  end if;

  select * into v_reco from recommendations
   where id = p_recommendation_id and deleted_at is null
   for update;
  if not found then
    raise exception 'recommendation not found' using errcode = 'P0002';
  end if;

  if v_reco.reward_status = 'pending' then
    raise exception 'this recommendation has not reached the reward stage yet'
      using errcode = '42501';
  end if;
  if v_reco.reward_status <> 'earned' then
    raise exception 'there is no commission to invoice: it is %', v_reco.reward_status
      using errcode = '42501';
  end if;

  if v_reco.reward_amount is null or v_reco.reward_amount <= 0 then
    raise exception 'set the commission on the recommendation before invoicing it'
      using errcode = '42501';
  end if;

  if has_live_invoice(p_recommendation_id) then
    raise exception 'this recommendation already has an invoice'
      using errcode = '23505';
  end if;

  -- the supplier's address is a mandatory mention, frozen at issue
  select * into v_apporteur from profiles where id = v_reco.parrain_id;
  if coalesce(btrim(v_apporteur.address), '') = ''
     or coalesce(btrim(v_apporteur.postal_code), '') = ''
     or coalesce(btrim(v_apporteur.city), '') = '' then
    raise exception 'L''adresse de facturation de % % est incomplète : il doit la renseigner dans son profil (Profil → Facturation) avant que la facture puisse être établie.',
      v_apporteur.first_name, v_apporteur.last_name
      using errcode = '23514', hint = 'apporteur_address_missing';
  end if;

  select * into v_issuer from profiles where id = v_uid;

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

  select * into v_inv from invoices where id = v_inv.id;
  return v_inv;
end;
$$;

-- ============================================================== grants
revoke execute on function public.request_sms_code(text, uuid, text, boolean) from public, anon;
revoke execute on function public.sms_text(text, text) from public, anon, authenticated;
grant execute on function public.request_sms_code(text, uuid, text, boolean) to authenticated, service_role;
grant execute on function public.sms_text(text, text) to service_role;
