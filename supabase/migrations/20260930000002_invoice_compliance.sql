-- Energy Courtage — an invoice that says what the law says it must.
--
-- The company issues each invoice in the apporteur's name (autofacturation,
-- art. 289, I-2 du CGI). What it produced was an "attestation" naming the
-- admin who clicked the button and their city. The mentions an invoice has to
-- carry (art. 242 nonies A, annexe II au CGI; art. L441-9 and L441-10 du Code
-- de commerce) were not there:
--   * "Autofacturation", since the customer drew it up;
--   * the customer's legal identity -- name, address, SIREN, VAT number -- not
--     the name of whichever employee issued it;
--   * the supplier's address and VAT number;
--   * a due date, the late-payment penalty rate, and the 40 € recovery fee;
--   * on a credit note, that it is one, and which invoice it cancels.
--
-- All of it is frozen into the invoice when it is issued, like the parties
-- already are, and it goes into the signed text. An invoice signed before
-- this file keeps the text it was signed on: canonical_version says which
-- rendering produced its digest.

-- ============================================== the company's identity
-- The customer on every invoice. Kept in one row, edited by an admin, because
-- it belongs to the company and not to the profile of whoever is signed in.
create table billing_settings (
  id                boolean primary key default true,
  legal_name        text not null,             -- raison sociale
  legal_form        text,                      -- SAS, SARL...
  share_capital     text,                      -- "10 000 €"
  siren             text not null,
  rcs_city          text,                      -- RCS de Lille
  vat_number        text,
  address           text not null,
  postal_code       text not null,
  city              text not null,
  -- art. L441-10: thirty days by default, sixty at most
  payment_term_days int  not null default 30,
  late_penalty_rate text not null default 'trois fois le taux d''intérêt légal',
  updated_at        timestamptz not null default now(),
  constraint billing_settings_singleton check (id),
  constraint billing_settings_siren check (siren ~ '^[0-9]{9}$'),
  constraint billing_settings_term check (payment_term_days between 0 and 60)
);

alter table billing_settings enable row level security;
create policy billing_settings_read on billing_settings for select to authenticated
  using (true);
create policy billing_settings_write on billing_settings for all to authenticated
  using ((select is_admin((select auth.uid()))))
  with check ((select is_admin((select auth.uid()))));
grant select, insert, update on billing_settings to authenticated;

create trigger billing_settings_touch before update on billing_settings
  for each row execute function public.touch_updated_at();

insert into invoice_texts (key, value) values
('self_billing',
 'Autofacturation — facture établie par le client au nom et pour le compte du fournisseur (art. 289, I-2 du CGI).'),
('late_payment',
 'En cas de retard de paiement, pénalités au taux de {taux}, exigibles sans rappel, et indemnité forfaitaire pour frais de recouvrement de 40 € (art. L441-10 du Code de commerce).')
on conflict (key) do nothing;

-- ============================================ what each invoice now keeps
alter table invoices
  add column customer_snapshot    jsonb,
  add column due_on               date,
  add column self_billing_mention text,
  add column late_payment_mention text,
  -- 1: the text invoices were signed on before this file; 2: with the above
  add column canonical_version    int not null default 1;

alter table invoices alter column canonical_version set default 2;

create or replace function public.snapshot_invoice_terms()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_settings billing_settings%rowtype;
begin
  select * into v_settings from billing_settings;
  if not found then
    raise exception
      'the company''s billing identity is not set up: fill in billing_settings before invoicing'
      using errcode = '55000';
  end if;

  new.canonical_version := 2;
  new.customer_snapshot := jsonb_build_object(
    'legal_name', v_settings.legal_name, 'legal_form', v_settings.legal_form,
    'share_capital', v_settings.share_capital, 'siren', v_settings.siren,
    'rcs_city', v_settings.rcs_city, 'vat_number', v_settings.vat_number,
    'address', v_settings.address, 'postal_code', v_settings.postal_code,
    'city', v_settings.city);
  new.due_on := coalesce(new.issued_on, current_date) + v_settings.payment_term_days;
  new.self_billing_mention := (select value from invoice_texts where key = 'self_billing');
  new.late_payment_mention := replace(
    (select value from invoice_texts where key = 'late_payment'),
    '{taux}', v_settings.late_penalty_rate);
  return new;
end;
$$;

create trigger invoices_snapshot_terms before insert on invoices
  for each row execute function public.snapshot_invoice_terms();

-- ================================================ what gets signed, v2
-- Version 1 is reproduced exactly, so the digest of every invoice signed
-- before this file can still be recomputed. Version 2 is the same text with
-- the new mentions after it.
create or replace function public.invoice_canonical_text(p_invoice_id uuid)
returns text
language sql
stable
as $$
  select concat_ws(E'\n',
    i.number,
    (i.issuer_snapshot ->> 'first_name') || ' ' || (i.issuer_snapshot ->> 'last_name'),
    coalesce(i.issuer_snapshot ->> 'company_name', ''),
    coalesce(i.issuer_snapshot ->> 'city', ''),
    (i.apporteur_snapshot ->> 'first_name') || ' ' || (i.apporteur_snapshot ->> 'last_name'),
    coalesce(i.apporteur_snapshot ->> 'siret', ''),
    i.filleul_name,
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
  || case when i.canonical_version >= 2 then E'\n' || concat_ws(E'\n',
    case when i.corrects_invoice_id is null then 'FACTURE' else 'AVOIR' end,
    coalesce((select o.number from invoices o where o.id = i.corrects_invoice_id), ''),
    coalesce(i.customer_snapshot ->> 'legal_name', ''),
    coalesce(i.customer_snapshot ->> 'siren', ''),
    coalesce(i.customer_snapshot ->> 'vat_number', ''),
    concat_ws(' ', i.customer_snapshot ->> 'address', i.customer_snapshot ->> 'postal_code',
                   i.customer_snapshot ->> 'city'),
    concat_ws(' ', i.apporteur_snapshot ->> 'address', i.apporteur_snapshot ->> 'postal_code',
                   i.apporteur_snapshot ->> 'city'),
    coalesce(i.apporteur_snapshot ->> 'vat_number', ''),
    coalesce(to_char(i.due_on, 'YYYY-MM-DD'), ''),
    coalesce(i.self_billing_mention, ''),
    coalesce(i.late_payment_mention, '')
  ) else '' end
  from invoices i
  where i.id = p_invoice_id;
$$;

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
  where i.id = p_invoice_id;
$$;

-- =============================================== the signature's evidence
-- The IP address and user agent kept with a signature were whatever the
-- client chose to send, which is not evidence of anything. PostgREST hands
-- the request's own headers to the database, so they are read there; a value
-- passed in is kept only when there is no request to read it from.
create or replace function public.request_header(p_name text)
returns text
language sql
stable
as $$
  select nullif(current_setting('request.headers', true), '')::json ->> lower(p_name);
$$;

create or replace function public.guard_invoice_signature()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inv invoices%rowtype;
  v_ip  text;
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

-- functions added here follow the rule set in 20260930000001
revoke execute on function public.request_header(text) from public, anon;
grant  execute on function public.request_header(text) to authenticated, service_role;
