-- Energy Courtage — what exactly gets signed.
--
-- A signature has to bind to a specific document. Earlier this leaned on
-- pdf_sha256, which meant nothing could be signed before a PDF existed, and
-- it asked the client to reproduce a canonical rendering byte for byte -- a
-- rule that silently breaks the first time either side reformats a line.
--
-- Instead the database derives the canonical text itself, hashes it once at
-- issuance, and that digest is the thing signed. The PDF becomes a rendering
-- of an already-signed document rather than the object of the signature.

create extension if not exists pgcrypto;

alter table invoices add column document_sha256 text;

-- The canonical form: every field that carries legal meaning, in a fixed
-- order, and nothing that varies between readings (no timestamps, no
-- signature state) or two honest signers would hash different things.
create or replace function public.invoice_canonical_text(p_invoice_id uuid)
returns text
language sql
stable
as $$
  select concat_ws(E'\n',
    i.number,
    issuer.first_name || ' ' || issuer.last_name,
    coalesce(issuer.company_name, ''),
    coalesce(issuer.city, ''),
    app.first_name || ' ' || app.last_name,
    coalesce(app.siret, ''),
    r.filleul_first_name || ' ' || r.filleul_last_name,
    i.prestation_label,
    to_char(i.intervened_on, 'YYYY-MM-DD'),
    to_char(i.amount_ht, 'FM999999990.00'),
    to_char(i.vat_rate,  'FM990.00'),
    to_char(i.vat_amount, 'FM999999990.00'),
    to_char(i.amount_ttc, 'FM999999990.00'),
    i.currency,
    i.legal_mentions,
    i.payment_method,
    i.place,
    to_char(i.issued_on, 'YYYY-MM-DD'),
    coalesce(i.tax_notice, '')
  )
  from invoices i
  join recommendations r on r.id = i.recommendation_id
  join profiles app    on app.id = i.apporteur_id
  join profiles issuer on issuer.id = i.issuer_id
  where i.id = p_invoice_id;
$$;

create or replace function public.stamp_invoice_digest()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update invoices
     set document_sha256 = encode(digest(invoice_canonical_text(new.id), 'sha256'), 'hex')
   where id = new.id;
  return null;
end;
$$;

create trigger invoices_stamp_digest after insert on invoices
  for each row execute function public.stamp_invoice_digest();

-- Signing no longer waits on a PDF; it waits on the digest, which always exists.
alter table invoices drop constraint invoice_signed_needs_pdf;
alter table invoices add constraint invoice_signed_needs_digest
  check (status not in ('signed', 'paid') or document_sha256 is not null);

create or replace function public.sign_invoice(
  p_invoice_id      uuid,
  p_document_sha256 text,
  p_ip              inet default null,
  p_user_agent      text default null
)
returns invoice_signatures
language plpgsql
as $$
declare
  v_uid  uuid := auth.uid();
  v_inv  invoices%rowtype;
  v_role signature_role;
  v_name text;
  v_sig  invoice_signatures%rowtype;
begin
  select * into v_inv from invoices where id = p_invoice_id;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;

  if v_inv.apporteur_id = v_uid then
    v_role := 'apporteur';
  elsif is_admin(v_uid) then
    v_role := 'entreprise';
  else
    raise exception 'you are not a party to this invoice' using errcode = '42501';
  end if;

  -- what is signed must be the document the server issued
  if v_inv.document_sha256 is distinct from p_document_sha256 then
    raise exception 'the document being signed does not match the issued invoice'
      using errcode = '22023';
  end if;

  select first_name || ' ' || last_name into v_name from profiles where id = v_uid;

  insert into invoice_signatures (invoice_id, signer_id, signer_role, signer_full_name,
                                  document_sha256, ip_address, user_agent)
  values (p_invoice_id, v_uid, v_role, v_name, p_document_sha256, p_ip, p_user_agent)
  returning * into v_sig;

  return v_sig;
end;
$$;

-- The viewer reads the digest from the same call that gives it the document,
-- so the client never has to reproduce the canonical form.
create or replace function public.invoice_document(p_invoice_id uuid)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'number', i.number,
    'document_sha256', i.document_sha256,
    'issuer', jsonb_build_object(
      'name',    issuer.first_name || ' ' || issuer.last_name,
      'company', issuer.company_name,
      'city',    issuer.city
    ),
    'apporteur', jsonb_build_object(
      'name',    app.first_name || ' ' || app.last_name,
      'company', app.company_name,
      'siret',   app.siret
    ),
    'attestation', jsonb_build_object(
      'soussigne',       app.first_name || ' ' || app.last_name,
      'mis_en_relation', issuer.company_name,
      'avec',            r.filleul_first_name || ' ' || r.filleul_last_name,
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
    'legal_mentions', i.legal_mentions,
    'payment_method', i.payment_method,
    'place',          i.place,
    'issued_on',      to_char(i.issued_on, 'DD.MM.YYYY'),
    'tax_notice',     i.tax_notice,
    'status',         i.status,
    'signatures', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'role',      expected.role,
               'name',      case expected.role
                              when 'apporteur'  then app.first_name || ' ' || app.last_name
                              else issuer.first_name || ' ' || issuer.last_name
                            end,
               'signed',    s.id is not null,
               'signed_at', s.signed_at
             ) order by expected.ord), '[]'::jsonb)
      from (values ('apporteur'::signature_role, 1), ('entreprise'::signature_role, 2))
           as expected(role, ord)
      left join invoice_signatures s
             on s.invoice_id = i.id and s.signer_role = expected.role
    )
  )
  from invoices i
  join recommendations r on r.id = i.recommendation_id
  join profiles app    on app.id = i.apporteur_id
  join profiles issuer on issuer.id = i.issuer_id
  where i.id = p_invoice_id;
$$;

-- Account deletion, reachable from the profile screen (App Store 5.1.1 v).
-- Invoices and their recommendations are legally retained, so the personal
-- data is cleared and the account is suspended rather than the rows removed.
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
         phone = null, avatar_url = null, iban_encrypted = null,
         address = null, postal_code = null,
         email = 'deleted+' || id::text || '@invalid'
   where id = v_uid;

  insert into audit_log (actor_id, entity, entity_id, action)
  values (v_uid, 'profiles', v_uid, 'account_deletion_requested');
end;
$$;
