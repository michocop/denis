-- Energy Courtage — the PDF that gets kept for ten years.
--
-- art. 242 nonies A ann. II CGI requires the issued invoice to be retained.
-- Until now nothing produced a file at all: pdf_path and pdf_sha256 existed
-- as columns and were never written, so "la facture" was a screen and
-- disappeared with the app.
--
-- The PDF is a RENDERING of a document that was already fixed and signed:
-- what the signature binds to is document_sha256, the digest of
-- invoice_canonical_text(). Asking two devices to reproduce identical PDF
-- bytes would make the signature break the first time either side reflowed a
-- line. So the file is written ONCE, by whoever gets there first after the
-- invoice is sealed, and everyone else reads that same file afterwards.

-- A private bucket. The invoice of an apporteur is nobody else's business,
-- and a public bucket would make every URL a permanent unauthenticated link.
insert into storage.buckets (id, name, public)
values ('invoices', 'invoices', false)
on conflict (id) do nothing;

-- The path is invoices/<invoice_id>.pdf, so who may read an object is exactly
-- who may read the invoice it is named after -- which RLS on invoices already
-- decides. Deriving it rather than restating it means the two cannot drift.
create or replace function public.invoice_id_from_object_name(p_name text)
returns uuid
language sql
immutable
as $$
  select nullif(regexp_replace(p_name, '\.pdf$', ''), '')::uuid;
$$;

drop policy if exists invoice_pdf_read on storage.objects;
create policy invoice_pdf_read on storage.objects for select to authenticated
  using (
    bucket_id = 'invoices'
    and exists (
      select 1 from invoices i
       where i.id = invoice_id_from_object_name(storage.objects.name)
         and (i.apporteur_id = (select auth.uid()) or is_admin((select auth.uid())))
    )
  );

-- Written only once the invoice is sealed: a PDF of a half-signed invoice
-- would be a document nobody agreed to, kept for ten years.
drop policy if exists invoice_pdf_write on storage.objects;
create policy invoice_pdf_write on storage.objects for insert to authenticated
  with check (
    bucket_id = 'invoices'
    and exists (
      select 1 from invoices i
       where i.id = invoice_id_from_object_name(storage.objects.name)
         and i.status in ('signed', 'paid')
         and (i.apporteur_id = (select auth.uid()) or is_admin((select auth.uid())))
    )
  );

-- No update and no delete policy at all: the retained document is not
-- replaceable, and an omitted policy denies by default.

-- ------------------------------------------------------- recording the file
-- The immutability guard freezes every column once an invoice is sealed,
-- which is right for the figures and wrong for the file: the PDF can only be
-- produced AFTER sealing, because it shows both signatures. So the two PDF
-- columns may go from null to a value, once, and never change afterwards.
create or replace function public.guard_invoice_immutability()
returns trigger
language plpgsql
as $$
begin
  if old.status in ('signed', 'paid', 'void') then
    if new.status is distinct from old.status
       and not (old.status = 'signed' and new.status in ('paid', 'void')) then
      raise exception 'invoice % is sealed: illegal status transition % -> %',
        old.number, old.status, new.status using errcode = '42501';
    end if;

    if old.pdf_path is not null and new.pdf_path is distinct from old.pdf_path then
      raise exception 'invoice % already has a retained document', old.number
        using errcode = '42501';
    end if;

    if to_jsonb(new) - 'status' - 'updated_at' - 'pdf_path' - 'pdf_sha256' is distinct from
       to_jsonb(old) - 'status' - 'updated_at' - 'pdf_path' - 'pdf_sha256' then
      raise exception 'invoice % is sealed and cannot be modified', old.number
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

-- The client uploads the bytes, then says so here. Returning the existing
-- path rather than raising on a second call makes the race harmless: two
-- devices opening the same invoice at once both upload, one wins, and the
-- loser is handed the winner's file instead of an error.
create or replace function public.record_invoice_pdf(
  p_invoice_id uuid,
  p_path       text,
  p_sha256     text
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_inv invoices%rowtype;
begin
  select * into v_inv from invoices where id = p_invoice_id;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;

  if v_inv.apporteur_id is distinct from auth.uid() and not is_admin(auth.uid()) then
    raise exception 'you are not a party to this invoice' using errcode = '42501';
  end if;

  if v_inv.status not in ('signed', 'paid') then
    raise exception 'invoice % is not signed yet', v_inv.number using errcode = '42501';
  end if;

  if v_inv.pdf_path is not null then
    return v_inv.pdf_path;
  end if;

  update invoices set pdf_path = p_path, pdf_sha256 = p_sha256, updated_at = now()
   where id = p_invoice_id;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (auth.uid(), 'invoices', p_invoice_id, 'pdf_retained',
          jsonb_build_object('path', p_path, 'sha256', p_sha256));

  return p_path;
end;
$$;

-- The viewer needs to know whether a file already exists before deciding to
-- render one, and invoice_document() is the only call it makes.
create or replace function public.invoice_document(p_invoice_id uuid)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'number', i.number,
    'document_sha256', i.document_sha256,
    'pdf_path', i.pdf_path,
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
