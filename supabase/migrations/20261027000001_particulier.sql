-- Energy Courtage — the particulier: an apporteur without a SIRET.
--
-- "Indépendant" now means a private individual who recommends now and then,
-- with no SIRET. Micro-entrepreneurs and sole traders choose "Société ou
-- entreprise" and give theirs. No law sets a ceiling for the particulier --
-- what the law asks is that the activity stays occasional -- so Trinity sets
-- one, written into the contract the particulier signs:
--   * 2 400 € of commissions per calendar year: the DAS2 threshold, so the
--     company never has a particulier to declare, and the year the revenue
--     is declared in;
--   * an alert from 1 800 €;
--   * no invoice that would take the year past 2 400 € until the apporteur
--     gives a SIRET, as a company or a micro-entreprise. The commission stays
--     earned, waiting.
-- Apporteurs who signed as indépendant before this gave a SIRET: they are
-- registered, not particuliers, and nothing changes for them.

-- ============================================================== who is one
-- A contract signed by a particulier carries no SIRET.
alter table apporteur_contracts alter column siret drop not null;

create or replace function public.is_particulier(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select business_status = 'independant'
       and regexp_replace(coalesce(siret, ''), '\D', '', 'g') = ''
      from profiles where id = p_profile), false);
$$;

create or replace function public.particulier_cap()
returns numeric language sql immutable as $$ select 2400.00::numeric $$;

create or replace function public.particulier_alert_from()
returns numeric language sql immutable as $$ select 1800.00::numeric $$;

-- What a year's invoices come to for one apporteur: credit notes, negative,
-- take back what they cancel; a voided draft never counted.
create or replace function public.commissions_invoiced_in(p_profile uuid, p_year int)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(amount_ht), 0)
    from invoices
   where apporteur_id = p_profile
     and status <> 'void'
     and extract(year from issued_on)::int = p_year;
$$;

-- 4 500 €, 1 234,50 €: the amounts in the messages, the French way.
create or replace function public.fr_euros(p_amount numeric)
returns text
language sql
immutable
as $$
  select regexp_replace(floor(abs(p_amount))::bigint::text, '(\d)(?=(\d{3})+$)', '\1 ', 'g')
      || case when round(abs(p_amount) % 1, 2) = 0 then ''
              else ',' || lpad((round(abs(p_amount) % 1, 2) * 100)::int::text, 2, '0') end
      || ' €';
$$;

revoke execute on function public.is_particulier(uuid) from public, anon;
revoke execute on function public.commissions_invoiced_in(uuid, int) from public, anon;

-- ============================================================ the ceiling
create or replace function public.cap_particulier_invoice()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year  int := extract(year from new.issued_on)::int;
  v_total numeric;
  v_name  text;
begin
  if new.corrects_invoice_id is not null or not is_particulier(new.apporteur_id) then
    return new;
  end if;
  v_total := commissions_invoiced_in(new.apporteur_id, v_year);
  if v_total + new.amount_ht > particulier_cap() then
    select btrim(first_name || ' ' || last_name) into v_name from profiles where id = new.apporteur_id;
    raise exception '% est particulier : ses commissions sont limitées à % par année civile, et % sont déjà facturés en %. Pour cette facture, il doit d''abord renseigner un SIRET (société ou micro-entreprise).',
      v_name, fr_euros(particulier_cap()), fr_euros(v_total), v_year
      using errcode = 'P0001', hint = 'particulier_cap';
  end if;
  return new;
end;
$$;

-- before the number is taken (invoices_assign_number runs first by name, but
-- a refused insert rolls the sequence back with it)
create trigger invoices_cap_particulier before insert on invoices
  for each row execute function public.cap_particulier_invoice();

-- Where the apporteur stands, for the app's alert and the company's view of
-- a member: the apporteur sees their own, an admin anyone's.
create or replace function public.commission_cap(p_profile uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile uuid := coalesce(p_profile, auth.uid());
  v_year    int  := extract(year from current_date)::int;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if v_profile <> auth.uid() and not is_admin(auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'particulier', is_particulier(v_profile),
    'year',        v_year,
    'total',       commissions_invoiced_in(v_profile, v_year),
    'cap',         particulier_cap(),
    'alert_from',  particulier_alert_from());
end;
$$;

revoke execute on function public.commission_cap(uuid) from public, anon;
grant execute on function public.commission_cap(uuid) to authenticated;

-- A particulier who enters a SIRET has registered: "Particulier" would then
-- be printed as the legal form of a business. It is dropped, for them to say
-- which form in its place.
create or replace function public.drop_particulier_form()
returns trigger
language plpgsql
as $$
begin
  if new.legal_form = 'Particulier'
     and regexp_replace(coalesce(new.siret, ''), '\D', '', 'g') <> '' then
    new.legal_form := null;
  end if;
  return new;
end;
$$;

create trigger profiles_drop_particulier_form before update of siret, legal_form on profiles
  for each row execute function public.drop_particulier_form();

-- ===================================================== the invoice's VAT line
-- A particulier is not liable for VAT: the 293 B exemption is for those who
-- are, so their invoices say why there is none in their own words.
insert into invoice_texts (key, value) values
('vat_particulier',
 'TVA non applicable – Apporteur d''affaires occasionnel, particulier non assujetti à la TVA')
on conflict (key) do nothing;

create or replace function public.compute_invoice_billing()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_liable boolean;
  v_orig   invoices%rowtype;
begin
  if new.corrects_invoice_id is not null then
    select * into v_orig from invoices where id = new.corrects_invoice_id;
    new.vat_mode       := v_orig.vat_mode;
    new.vat_rate       := v_orig.vat_rate;
    new.legal_mentions := v_orig.legal_mentions;
    new.tax_notice     := v_orig.tax_notice;
  else
    select vat_liable into v_liable from profiles where id = new.apporteur_id;

    if coalesce(v_liable, false) then
      new.vat_mode       := 'standard';
      new.vat_rate       := 20.00;
      new.legal_mentions := (select value from invoice_texts where key = 'vat_standard');
    else
      new.vat_mode       := 'franchise_293b';
      new.vat_rate       := 0;
      new.legal_mentions := (select value from invoice_texts
                              where key = case when is_particulier(new.apporteur_id)
                                               then 'vat_particulier' else 'vat_exempt_293b' end);
    end if;
    new.tax_notice := coalesce(new.tax_notice,
                               (select value from invoice_texts where key = 'tax_notice'));
  end if;

  new.vat_amount := round(new.amount_ht * new.vat_rate / 100, 2);
  new.amount_ttc := new.amount_ht + new.vat_amount;
  return new;
end;
$$;

-- ============================================================= the texts
-- The contract says who may sign without a SIRET, and the ceiling.
update legal_documents set active = false where key = 'contrat_apporteur' and active;

insert into legal_documents (key, version, title, body, sha256, active)
values ('contrat_apporteur', '2026-10-2', 'Contrat d''apporteur d''affaires', '**Entre les soussignés :**

**TRINITY ENERGIE**, société par actions simplifiée au capital de 1 000 €, dont
le siège social est situé 945 rue du Général de Gaulle, 59310 Aix-en-Pévèle,
immatriculée au RCS de Lille Métropole sous le numéro 102 470 705, représentée
par Pierre-Louis Tettamanti, en qualité de Président,

ci-après « **la Société** »,

**Et :**

l''apporteur d''affaires titulaire du compte depuis lequel le présent contrat est
signé, exerçant en société, en entreprise individuelle ou en qualité de
particulier, dont l''identité, le statut, l''adresse et, le cas échéant, le
numéro SIRET sont ceux renseignés lors de la signature et reproduits dans le
certificat de signature annexé,

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

L''Apporteur exerce son activité en toute indépendance, avec ses propres
moyens et à ses propres risques. Le
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
dans l''application, son statut, ses coordonnées et, s''il en a un, son numéro
SIRET, et à signaler sans délai tout changement de régime de TVA.

## Article 6 — Obligations fiscales et sociales

L''Apporteur qui exerce en société ou en entreprise individuelle déclare être
régulièrement immatriculé et s''acquitter lui-même des déclarations et
cotisations fiscales et sociales afférentes aux commissions perçues. Il en
justifie à première demande de la Société.

L''Apporteur particulier, sans numéro SIRET, exerce cette activité à titre
occasionnel. Il déclare lui-même les commissions perçues dans sa déclaration
de revenus, au titre des bénéfices non commerciaux.

**Plafond du particulier.** Les commissions de l''Apporteur particulier sont
limitées à **2 400 € par année civile**. **Au-delà de ce montant, l''Apporteur
doit exercer en société ou en entreprise individuelle immatriculée
(micro-entreprise comprise)** et renseigner son numéro SIRET dans
l''application. Tant qu''il ne l''a pas fait, aucune facture portant ses
commissions au-delà de ce plafond n''est établie, et les commissions
correspondantes restent acquises mais en attente de règlement.

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

Version du 27 octobre 2026.', '', true)
on conflict (key, version) do nothing;

-- The mandate named "le numéro SIREN" as if every mandant had one. The
-- company's own mandate lives in its seed; its active version, when it has
-- that wording, gets a successor saying "le cas échéant".
do $$
declare
  v_doc legal_documents%rowtype;
begin
  select * into v_doc from legal_documents where key = 'mandat_facturation' and active;
  if v_doc.key is not null and v_doc.version = '2026-10-1'
     and v_doc.body like '%l''adresse et le numéro SIREN sont ceux%' then
    update legal_documents set active = false where key = v_doc.key and version = v_doc.version;
    insert into legal_documents (key, version, title, body, sha256, active)
    values (v_doc.key, '2026-10-2', v_doc.title,
            replace(v_doc.body,
                    'le statut, l''adresse et le numéro SIREN sont ceux
renseignés dans son profil',
                    'le statut, l''adresse et, le cas échéant, le numéro SIREN
sont ceux renseignés dans son profil'),
            '', true)
    on conflict (key, version) do nothing;
  end if;
end;
$$;

-- ============================================================== signing
-- As before, with the particulier: no SIRET, and none kept. A company needs
-- its name, a micro-entrepreneur or sole trader trades under their own.
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
  v_form     text;
  v_company  text;
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
  if p_business_status = 'independant' then
    v_siret   := null;
    v_form    := 'Particulier';
    v_company := null;
    if coalesce(btrim(v_prof.address), '') = ''
       or coalesce(btrim(v_prof.postal_code), '') = ''
       or coalesce(btrim(v_prof.city), '') = '' then
      raise exception 'Complétez votre adresse.'
        using errcode = 'P0001', hint = 'profile_incomplete';
    end if;
  else
    v_siret   := regexp_replace(coalesce(v_prof.siret, ''), '\D', '', 'g');
    v_form    := nullif(btrim(v_prof.legal_form), '');
    v_company := nullif(btrim(v_prof.company_name), '');
    if length(v_siret) <> 14
       or coalesce(btrim(v_prof.address), '') = ''
       or coalesce(btrim(v_prof.postal_code), '') = ''
       or coalesce(btrim(v_prof.city), '') = ''
       or (v_company is null
           and coalesce(v_form, '') not in ('Micro-entrepreneur', 'Entreprise individuelle')) then
      raise exception 'Complétez votre SIRET, votre adresse%.',
        case when coalesce(v_form, '') in ('Micro-entrepreneur', 'Entreprise individuelle')
             then '' else ' et votre raison sociale' end
        using errcode = 'P0001', hint = 'profile_incomplete';
    end if;
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
         legal_form = v_form,
         company_name = v_company,
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
    v_company, v_form, v_siret,
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
