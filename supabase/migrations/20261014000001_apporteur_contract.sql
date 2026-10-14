-- Energy Courtage — the apporteur's contract, signed once, by SMS, at the door.
--
-- An apporteur used to arrive straight on the dashboard, with a notice asking
-- for the billing mandate somewhere down the page. Now the first sign-in asks
-- three things, in order:
--   * how they work: as a company (société) or on their own (indépendant),
--     and the identity that goes with it;
--   * to read the contrat d'apporteur d'affaires, the billing mandate as its
--     annex;
--   * to sign both with one code sent by SMS to their mobile.
-- What was signed is kept as a snapshot (apporteur_contracts) -- who, under
-- which status, which texts to the byte, from which number -- and filed as a
-- PDF that the apporteur and the company's admins can open from the app.

-- ================================================================ status
alter table profiles add column business_status text
  check (business_status in ('societe', 'independant'));
-- Set by sign_apporteur_contract only: the contract is what admits someone.
alter table profiles add column contract_signed_at timestamptz;

create or replace function public.guard_contract_columns()
returns trigger
language plpgsql
as $$
begin
  if auth.uid() is not null
     and coalesce(current_setting('app.recording_contract', true), '') <> 'on'
     and new.contract_signed_at is distinct from old.contract_signed_at then
    raise exception 'contract_signed_at is set by signing the contract' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger profiles_guard_contract before update on profiles
  for each row execute function public.guard_contract_columns();

-- ============================================================= the text
-- In the migration rather than the seed: the onboarding cannot finish without
-- it, so a deploy that brings the screens brings the text. Inactive versions
-- of it can still be published later from the back-office.
insert into legal_documents (key, version, title, body, sha256, active)
values ('contrat_apporteur', '2026-10-1', 'Contrat d''apporteur d''affaires', '**Entre les soussignés :**

**TRINITY ENERGIE**, société par actions simplifiée au capital de 1 000 €, dont
le siège social est situé 945 rue du Général de Gaulle, 59310 Aix-en-Pévèle,
immatriculée au RCS de Lille Métropole sous le numéro 102 470 705, représentée
par Pierre-Louis Tettamanti, en qualité de Président,

ci-après « **la Société** »,

**Et :**

l''apporteur d''affaires titulaire du compte depuis lequel le présent contrat est
signé, exerçant en société ou en qualité d''indépendant, dont l''identité, le
statut, l''adresse et le numéro SIRET sont ceux renseignés lors de la signature
et reproduits dans le certificat de signature annexé,

ci-après « **l''Apporteur** ».

## Article 1 — Objet

Le présent contrat définit les conditions dans lesquelles l''Apporteur met la
Société en relation avec des professionnels et des particuliers susceptibles
de lui confier le courtage de leurs contrats d''électricité et de gaz, et la
rémunération qui lui est due à ce titre.

## Article 2 — Mission de l''Apporteur

L''Apporteur transmet à la Société, par l''intermédiaire de l''application, les
coordonnées de personnes intéressées par ses services. Il s''engage à :

- n''adresser que des personnes qu''il a **préalablement informées** de cette
  transmission et dont il a recueilli l''accord ;
- transmettre des informations exactes, obtenues de manière licite ;
- ne jamais se présenter comme salarié, mandataire ou représentant de la
  Société, ni formuler d''offre, de prix ou d''engagement en son nom ;
- respecter la confidentialité des informations dont il a connaissance.

La négociation et la conclusion des contrats relèvent de la seule Société.

## Article 3 — Indépendance

L''Apporteur exerce son activité en toute indépendance, en société ou en
qualité d''indépendant, avec ses propres moyens et à ses propres risques. Le
présent contrat ne crée ni lien de subordination, ni contrat de travail, ni
mandat de représentation, ni exclusivité de part et d''autre. L''Apporteur
demeure libre d''organiser son activité et d''en exercer d''autres.

## Article 4 — Rémunération

Pour chaque mise en relation aboutissant à la signature d''un contrat par la
personne recommandée, l''Apporteur perçoit une commission :

- dont le montant est fixé pour chaque recommandation et affiché dans
  l''application ;
- **acquise à la signature du devis** par la personne recommandée ;
- réglée par virement dans un délai de 30 jours à compter de la signature de la
  facture correspondante par les deux parties.

Aucune commission n''est due lorsque la personne recommandée était déjà connue
de la Société ou suivie au titre d''une recommandation antérieure, ni en cas
d''annulation, de rétractation ou d''impayé.

## Article 5 — Facturation

Les factures de commission sont établies par la Société au nom et pour le
compte de l''Apporteur, selon le **mandat de facturation** annexé au présent
contrat et signé en même temps que lui. L''Apporteur s''engage à tenir à jour,
dans l''application, son statut, ses coordonnées et son numéro SIRET, et à
signaler sans délai tout changement de régime de TVA.

## Article 6 — Obligations fiscales et sociales

L''Apporteur déclare être régulièrement immatriculé et s''acquitter lui-même des
déclarations et cotisations fiscales et sociales afférentes aux commissions
perçues. Il en justifie à première demande de la Société.

## Article 7 — Données personnelles

Chaque partie respecte la réglementation applicable à la protection des
données personnelles. Les données des personnes recommandées sont traitées
conformément à la politique de confidentialité de l''application.

## Article 8 — Durée et résiliation

Le présent contrat prend effet à la date de sa signature, pour une durée
indéterminée. Chaque partie peut y mettre fin à tout moment par écrit, moyennant
un préavis de 30 jours. Les commissions acquises avant la fin du contrat
restent dues. En cas de manquement grave, notamment à l''article 2, la Société
peut y mettre fin sans préavis.

## Article 9 — Signature électronique

Les parties conviennent que la signature électronique apposée via
l''application, confirmée par un code à usage unique reçu par SMS, constitue une
signature au sens des articles 1366 et 1367 du Code civil et vaut preuve de
leur consentement. La date, l''heure, le numéro de mobile vérifié et
l''empreinte des documents signés sont conservés dans le certificat annexé.

## Article 10 — Droit applicable

Le présent contrat est soumis au droit français. À défaut de résolution
amiable, tout litige relève des tribunaux du ressort de la cour d''appel de
Douai.

Version du 14 octobre 2026.', '', true)
on conflict (key, version) do nothing;

-- ========================================================= the record
-- What was signed, as it was: the profile changes, this does not. The PDF
-- prints it, and the texts are kept by version and digest in legal_documents.
create table apporteur_contracts (
  id                uuid primary key default gen_random_uuid(),
  profile_id        uuid not null references profiles(id) on delete restrict,
  contract_version  text not null,
  contract_sha256   text not null,
  mandate_version   text not null,
  mandate_sha256    text not null,
  business_status   text not null check (business_status in ('societe', 'independant')),
  signer_full_name  text not null,
  email             text not null,
  company_name      text,
  legal_form        text,
  siret             text not null,
  address           text not null,
  postal_code       text not null,
  city              text not null,
  otp_verified      boolean not null default false,
  otp_phone         text,               -- masked: +33 6 •• •• •• 14
  ip_address        inet,
  user_agent        text,
  signed_at         timestamptz not null default now(),
  pdf_path          text,
  pdf_sha256        text
);
create index apporteur_contracts_profile_idx on apporteur_contracts (profile_id, signed_at desc);

alter table apporteur_contracts enable row level security;
revoke all on apporteur_contracts from authenticated, anon;
grant select on apporteur_contracts to authenticated;
create policy apporteur_contracts_read on apporteur_contracts for select to authenticated
  using (profile_id = (select auth.uid()) or is_admin((select auth.uid())));

-- ================================================================== SMS
alter table sms_codes drop constraint if exists sms_codes_purpose_check;
alter table sms_codes add constraint sms_codes_purpose_check
  check (purpose in ('verify_phone', 'sign_invoice', 'sign_contract'));

create or replace function public.sms_text(p_purpose text, p_code text)
returns text
language sql
immutable
as $$
  select case p_purpose
    when 'sign_invoice' then
      'Trinity Énergie : ' || p_code || ' est votre code de signature. '
      || 'Valable 10 minutes. Ne le communiquez à personne.'
    when 'sign_contract' then
      'Trinity Énergie : ' || p_code || ' est votre code pour signer votre contrat. '
      || 'Valable 10 minutes.'
    else
      'Trinity Énergie : ' || p_code || ' est votre code de vérification. '
      || 'Valable 10 minutes.'
  end;
$$;

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

  if p_purpose in ('sign_invoice', 'sign_contract') then
    if p_purpose = 'sign_invoice' then
      select * into v_inv from invoices where id = p_invoice_id;
      if not found or v_inv.apporteur_id is distinct from v_uid then
        raise exception 'invoice not found' using errcode = 'P0002';
      end if;
      if v_inv.status not in ('draft', 'awaiting_signatures') then
        raise exception 'Cette facture ne peut plus être signée.' using errcode = '42501';
      end if;
    end if;
    if not sms_signature_required() then
      return jsonb_build_object('required', false);
    end if;

    -- a code confirmed in the last ten minutes still covers this signature
    select * into v_live from sms_codes
     where profile_id = v_uid and purpose = p_purpose and consumed_at is null
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

-- Unchanged but for the window: a contract code, like an invoice code, stays
-- open for the signature that follows it.
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

  -- any purpose proves the number the code went to
  select * into v_prof from profiles where id = v_uid;
  if v_prof.phone_verified_at is null or normalise_mobile(v_prof.phone) is distinct from v_row.phone then
    update profiles set phone = v_row.phone, phone_verified_at = now() where id = v_uid;
    insert into audit_log (actor_id, entity, entity_id, action, after)
    values (v_uid, 'profiles', v_uid, 'verify_phone',
            jsonb_build_object('phone', mask_phone(v_row.phone), 'via', p_purpose));
  end if;

  return jsonb_build_object('ok', true, 'masked_phone', mask_phone(v_row.phone),
    'valid_until', case when p_purpose in ('sign_invoice', 'sign_contract')
                        then now() + interval '10 minutes' end);
end;
$$;

-- ============================================================ signing
-- The contract and its annex, the mandate, in one act: one code, two
-- acceptances, one record, one PDF. Everything the record holds is read here,
-- on the server, from the profile -- the app sends only the status and the
-- digests of the texts it showed.
create or replace function public.sign_apporteur_contract(
  p_business_status text,
  p_contract_sha256 text,
  p_mandate_sha256  text
)
returns apporteur_contracts
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid      uuid := auth.uid();
  v_prof     profiles%rowtype;
  v_contract legal_documents%rowtype;
  v_mandate  legal_documents%rowtype;
  v_code     sms_codes%rowtype;
  v_row      apporteur_contracts%rowtype;
  v_ip       text;
  v_siret    text;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select * into v_prof from profiles where id = v_uid for update;
  if not found or v_prof.status <> 'active' then
    raise exception 'only an active member can sign' using errcode = '42501';
  end if;
  if p_business_status not in ('societe', 'independant') then
    raise exception 'Indiquez si vous exercez en société ou en indépendant.'
      using errcode = '22023', hint = 'business_status';
  end if;

  -- the identity the contract and every invoice will carry
  v_siret := regexp_replace(coalesce(v_prof.siret, ''), '\D', '', 'g');
  if length(v_siret) <> 14
     or coalesce(btrim(v_prof.address), '') = ''
     or coalesce(btrim(v_prof.postal_code), '') = ''
     or coalesce(btrim(v_prof.city), '') = ''
     or (p_business_status = 'societe' and coalesce(btrim(v_prof.company_name), '') = '') then
    raise exception 'Complétez votre SIRET, votre adresse%.',
      case when p_business_status = 'societe' then ' et votre raison sociale' else '' end
      using errcode = 'P0001', hint = 'profile_incomplete';
  end if;

  select * into v_contract from legal_documents where key = 'contrat_apporteur' and active;
  select * into v_mandate  from legal_documents where key = 'mandat_facturation' and active;
  if v_contract.key is null or v_mandate.key is null then
    raise exception 'Le contrat n''est pas encore publié.' using errcode = 'P0002';
  end if;
  if p_contract_sha256 is distinct from v_contract.sha256
     or p_mandate_sha256 is distinct from v_mandate.sha256 then
    raise exception 'Le texte affiché n''est plus celui en vigueur : rouvrez-le avant de signer.'
      using errcode = '22023', hint = 'document_changed';
  end if;

  -- the code confirmed in the last ten minutes, used up by this signature
  if sms_signature_required() then
    select * into v_code from sms_codes
     where profile_id = v_uid and purpose = 'sign_contract'
       and verified_at > now() - interval '10 minutes' and consumed_at is null
     order by verified_at desc
     limit 1
     for update;
    if not found then
      raise exception 'Un code SMS est nécessaire pour signer.' using errcode = '42501',
        hint = 'sms_required';
    end if;
    update sms_codes set consumed_at = now() where id = v_code.id;
  end if;

  perform set_config('app.recording_contract', 'on', true);
  update profiles
     set business_status = p_business_status,
         siret = v_siret,
         contract_signed_at = coalesce(contract_signed_at, now())
   where id = v_uid;

  -- the two texts, accepted as any other: the mandate's acceptance is what
  -- lets invoices be issued in the apporteur's name
  perform accept_legal_document('contrat_apporteur', v_contract.sha256);
  perform accept_legal_document('mandat_facturation', v_mandate.sha256);

  v_ip := btrim(split_part(coalesce(request_header('x-forwarded-for'),
                                    request_header('x-real-ip'), ''), ',', 1));

  insert into apporteur_contracts (
    profile_id, contract_version, contract_sha256, mandate_version, mandate_sha256,
    business_status, signer_full_name, email, company_name, legal_form, siret,
    address, postal_code, city, otp_verified, otp_phone, user_agent)
  values (
    v_uid, v_contract.version, v_contract.sha256, v_mandate.version, v_mandate.sha256,
    p_business_status, v_prof.first_name || ' ' || v_prof.last_name, v_prof.email,
    nullif(btrim(v_prof.company_name), ''), nullif(btrim(v_prof.legal_form), ''), v_siret,
    btrim(v_prof.address), btrim(v_prof.postal_code), btrim(v_prof.city),
    v_code.id is not null, mask_phone(v_code.phone), request_header('user-agent'))
  returning * into v_row;

  if v_ip <> '' then
    begin
      update apporteur_contracts set ip_address = v_ip::inet where id = v_row.id
      returning * into v_row;
    exception when others then
      null;
    end;
  end if;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_uid, 'apporteur_contracts', v_row.id, 'sign_contract',
          jsonb_build_object('status', p_business_status, 'contract', v_contract.version,
                             'mandate', v_mandate.version, 'sms', v_row.otp_verified));

  -- the company hears of it
  insert into notifications (profile_id, kind, payload)
  select p.id, 'contract_signed',
         jsonb_build_object('apporteur', v_row.signer_full_name, 'contract_id', v_row.id,
                            'apporteur_id', v_uid)
    from profiles p
   where p.role = 'admin' and p.status = 'active';

  perform call_edge_hook('contract-pdf', jsonb_build_object('contract_id', v_row.id));
  return v_row;
end;
$$;

revoke execute on function public.sign_apporteur_contract(text, text, text) from public, anon;
grant execute on function public.sign_apporteur_contract(text, text, text) to authenticated;

-- ================================================================= PDF
insert into storage.buckets (id, name, public)
values ('contracts', 'contracts', false)
on conflict (id) do nothing;

-- contracts/<contract id>.pdf: readable by whoever may read the record
drop policy if exists contract_pdf_read on storage.objects;
create policy contract_pdf_read on storage.objects for select to authenticated
  using (
    bucket_id = 'contracts'
    and exists (
      select 1 from apporteur_contracts c
       where c.id = invoice_id_from_object_name(storage.objects.name)
         and (c.profile_id = (select auth.uid()) or is_admin((select auth.uid())))
    )
  );

-- What the renderer prints: the record, both texts, and the company.
create or replace function public.contract_document(p_contract_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', c.id,
    'signed_at', c.signed_at,
    'business_status', c.business_status,
    'signer', jsonb_build_object(
      'name', c.signer_full_name, 'email', c.email, 'company', c.company_name,
      'legal_form', c.legal_form, 'siret', c.siret, 'address', c.address,
      'postal_code', c.postal_code, 'city', c.city),
    'evidence', jsonb_build_object(
      'sms_verified', c.otp_verified, 'sms_phone', c.otp_phone,
      'ip_address', host(c.ip_address), 'user_agent', c.user_agent),
    'contract', jsonb_build_object('title', d.title, 'version', d.version,
                                   'sha256', d.sha256, 'body', d.body),
    'mandate', jsonb_build_object('title', m.title, 'version', m.version,
                                  'sha256', m.sha256, 'body', m.body),
    'company', (select jsonb_build_object(
                  'legal_name', b.legal_name, 'legal_form', b.legal_form,
                  'share_capital', b.share_capital, 'siren', b.siren, 'rcs_city', b.rcs_city,
                  'address', b.address, 'postal_code', b.postal_code, 'city', b.city)
                  from billing_settings b limit 1),
    'pdf_path', c.pdf_path)
  from apporteur_contracts c
  join legal_documents d on d.key = 'contrat_apporteur' and d.version = c.contract_version
  join legal_documents m on m.key = 'mandat_facturation' and m.version = c.mandate_version
  where c.id = p_contract_id;
$$;

-- Set once, by the renderer: the filed copy does not change afterwards.
create or replace function public.retain_contract_pdf(p_contract_id uuid, p_path text, p_sha256 text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_path text;
begin
  if p_path is distinct from p_contract_id::text || '.pdf' or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'unexpected path or digest' using errcode = '22023';
  end if;
  update apporteur_contracts
     set pdf_path = p_path, pdf_sha256 = p_sha256
   where id = p_contract_id and pdf_path is null
  returning pdf_path into v_path;
  if v_path is null then
    select pdf_path into v_path from apporteur_contracts where id = p_contract_id;
  else
    insert into audit_log (actor_id, entity, entity_id, action, after)
    values (null, 'apporteur_contracts', p_contract_id, 'retain_pdf',
            jsonb_build_object('path', p_path, 'sha256', p_sha256));
  end if;
  return v_path;
end;
$$;

revoke execute on function public.contract_document(uuid) from public, anon, authenticated;
revoke execute on function public.retain_contract_pdf(uuid, text, text) from public, anon, authenticated;
grant execute on function public.contract_document(uuid) to service_role;
grant execute on function public.retain_contract_pdf(uuid, text, text) to service_role;

-- A PDF the hook missed (the function asleep, a deploy in between) is asked
-- for again by the sweep, as invoices are.
create or replace function public.request_missing_contract_pdfs()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid; v_count int := 0;
begin
  for v_id in select id from apporteur_contracts
               where pdf_path is null and signed_at < now() - interval '2 minutes'
               order by signed_at limit 20 loop
    if call_edge_hook('contract-pdf', jsonb_build_object('contract_id', v_id)) then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;
revoke execute on function public.request_missing_contract_pdfs() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('contract-pdf-sweep', '*/15 * * * *',
                          'select public.request_missing_contract_pdfs()');
  end if;
exception when others then
  raise notice 'pg_cron unavailable: the contract PDF sweep is not scheduled';
end $$;

-- ===================================================== notifications
create or replace function public.notification_title(p_kind text, p_payload jsonb)
returns text
language sql
immutable
as $$
  select case p_kind
    when 'stage_advanced'   then 'Votre recommandation avance'
    when 'reward_earned'    then 'Commission acquise'
    when 'message_received' then coalesce(p_payload ->> 'sender', 'Nouveau message')
    when 'invoice_ready'    then 'Facture à signer'
    when 'payment_sent'     then 'Paiement envoyé'
    when 'reminder_due'     then 'Relance'
    when 'lead_created'     then 'Nouvelle recommandation'
    when 'member_pending'   then 'Inscription à valider'
    when 'invoice_signed_by_apporteur' then 'Facture à contresigner'
    when 'document_added'   then 'Nouveau document'
    when 'member_approved'  then 'Compte activé'
    when 'recommendation_lost' then 'Recommandation sans suite'
    when 'invoice_signed'   then 'Facture signée'
    when 'contract_signed'  then 'Contrat signé'
    else 'Notification'
  end;
$$;

create or replace function public.notification_body(p_kind text, p_payload jsonb)
returns text
language sql
immutable
as $$
  select case p_kind
    when 'stage_advanced' then
      coalesce(p_payload ->> 'filleul', 'Votre filleul') || ' : '
      || coalesce(p_payload ->> 'stage_label', 'étape suivante')
    when 'reward_earned' then
      coalesce(p_payload ->> 'filleul', 'Votre filleul') || ' a signé'
      || coalesce(' — ' || format_euros(p_payload ->> 'amount'), '')
    when 'message_received' then coalesce(p_payload ->> 'excerpt', '')
    when 'invoice_ready' then
      'Facture ' || coalesce(p_payload ->> 'number', '')
      || coalesce(' — ' || format_euros(p_payload ->> 'amount'), '')
    when 'payment_sent' then
      coalesce(format_euros(p_payload ->> 'amount'), 'Votre paiement') || ' en route'
    when 'reminder_due' then
      coalesce(p_payload ->> 'label', 'Relance prévue')
      || coalesce(' — ' || (p_payload ->> 'filleul'), '')
    when 'lead_created' then
      coalesce(p_payload ->> 'filleul', 'Un filleul')
      || coalesce(', recommandé par ' || (p_payload ->> 'parrain'), '')
    when 'member_pending' then
      coalesce(p_payload ->> 'name', 'Un nouveau membre') || ' attend votre validation'
    when 'invoice_signed_by_apporteur' then
      coalesce(p_payload ->> 'apporteur', 'L''apporteur') || ' a signé la facture '
      || coalesce(p_payload ->> 'number', '')
    when 'document_added' then
      coalesce(p_payload ->> 'filename', 'Un document')
      || coalesce(' — ' || (p_payload ->> 'filleul'), '')
    when 'member_approved' then
      'Votre compte est validé : vous pouvez recommander vos premiers contacts.'
    when 'recommendation_lost' then
      'Le dossier de ' || coalesce(p_payload ->> 'filleul', 'votre filleul')
      || ' est clôturé sans suite.'
    when 'invoice_signed' then
      'Facture ' || coalesce(p_payload ->> 'number', '') || ' signée des deux parties'
      || coalesce(' — ' || format_euros(p_payload ->> 'amount'), '')
    when 'contract_signed' then
      coalesce(p_payload ->> 'apporteur', 'Un apporteur')
      || ' a signé son contrat d''apporteur d''affaires.'
    else ''
  end;
$$;

create or replace function public.is_email_worthy(p_kind text)
returns boolean
language sql
immutable
as $$
  select p_kind in ('invoice_ready', 'reward_earned', 'payment_sent', 'reminder_due',
                    'lead_created', 'member_pending', 'invoice_signed_by_apporteur',
                    'document_added', 'member_approved', 'contract_signed');
$$;

-- ====================================================== the console
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
  p.business_status,
  c.id        as contract_id,
  c.signed_at as contract_signed_at,
  c.pdf_path is not null as contract_pdf_ready,
  count(r.id) filter (where r.deleted_at is null)                as total_recommendations,
  count(r.id) filter (where r.status = 'active' and r.deleted_at is null) as active_recommendations,
  coalesce(sum(r.reward_amount) filter (where r.reward_status = 'paid'), 0)  as paid_total,
  coalesce(sum(r.reward_amount) filter (where r.reward_status in ('earned','invoiced')), 0) as owed_total,
  max(r.created_at) as last_recommendation_at
from profiles p
left join lateral (
  select id, signed_at, pdf_path from apporteur_contracts
   where profile_id = p.id order by signed_at desc limit 1
) c on true
left join recommendations r on r.parrain_id = p.id
group by p.id, c.id, c.signed_at, c.pdf_path;

grant select on member_overview to authenticated;
