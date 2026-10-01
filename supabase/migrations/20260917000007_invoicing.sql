-- Energy Courtage — invoicing rules.
--
-- The source app generates the apporteur's invoice from the company's system.
-- That is self-billing (auto-facturation), which carries obligations the UI
-- gives no hint of. They are enforced here rather than in the client, because
-- a client-side tax rule is a suggestion.

-- ---------------------------------------------------------- legal wording
-- Editable from the back-office: tax wording changes, builds shouldn't have to.
create table invoice_texts (
  key   text primary key,
  value text not null
);

insert into invoice_texts (key, value) values
('vat_exempt_293b',
 'TVA non applicable – Régime d''exonération de TVA (Article 293B du Code général des impôts)'),
('vat_standard',
 'TVA au taux normal de 20 % – TVA acquittée sur les débits'),
('tax_notice',
 'N''oubliez pas de procéder à votre déclaration de revenu en fin d''année.
Si vous êtes un apporteur d''affaire occasionnel, vous devez déclarer les sommes perçues au titre des bénéfices non commerciaux (BNC) via votre déclaration de revenus - CERFA 2042 C -');

alter table invoice_texts enable row level security;
create policy invoice_texts_read on invoice_texts for select to authenticated using (true);
create policy invoice_texts_write on invoice_texts for all to authenticated
  using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

-- ------------------------------------------------- VAT is derived, not typed
-- Whether the invoice carries the 293B exemption or real VAT depends on the
-- apporteur's own tax situation, so neither the admin nor the client gets to
-- choose it. An apporteur who crosses the franchise threshold starts being
-- invoiced with VAT automatically.
create or replace function public.compute_invoice_billing()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_liable boolean;
begin
  select vat_liable into v_liable from profiles where id = new.apporteur_id;

  if coalesce(v_liable, false) then
    new.vat_mode       := 'standard';
    new.vat_rate       := 20.00;
    new.legal_mentions := (select value from invoice_texts where key = 'vat_standard');
  else
    new.vat_mode       := 'franchise_293b';
    new.vat_rate       := 0;
    new.legal_mentions := (select value from invoice_texts where key = 'vat_exempt_293b');
  end if;

  new.vat_amount := round(new.amount_ht * new.vat_rate / 100, 2);
  new.amount_ttc := new.amount_ht + new.vat_amount;
  new.tax_notice := coalesce(new.tax_notice,
                             (select value from invoice_texts where key = 'tax_notice'));
  return new;
end;
$$;

create trigger invoices_compute_billing before insert on invoices
  for each row execute function public.compute_invoice_billing();

-- ------------------------------------------------ the self-billing mandate
-- Issuing an invoice in someone else's name requires their prior written
-- mandate. "Prior" is the whole point, so a mandate signed after the invoice
-- date does not count.
create or replace function public.require_billing_mandate()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signed timestamptz;
begin
  select billing_mandate_signed_at into v_signed
    from profiles where id = new.apporteur_id;

  if v_signed is null then
    raise exception
      'no self-billing mandate on file for this apporteur: it must be signed before invoicing'
      using errcode = '42501';
  end if;

  if v_signed::date > new.issued_on then
    raise exception 'the self-billing mandate must predate the invoice'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger invoices_require_mandate before insert on invoices
  for each row execute function public.require_billing_mandate();

-- -------------------------------------------------- the document contract
-- One shape, consumed by both the PDF renderer and the in-app viewer, so the
-- signed PDF and what the apporteur read can never drift apart.
-- Field names and wording mirror the source app's document exactly.
create or replace function public.invoice_document(p_invoice_id uuid)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'number', i.number,
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
