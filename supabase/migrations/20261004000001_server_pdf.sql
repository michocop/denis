-- Energy Courtage — the server keeps the ten-year copy.
--
-- The retained PDF was drawn on a phone and uploaded by whichever company
-- admin opened the signed invoice. An invoice nobody opened was never kept,
-- and art. 242 nonies A ann. II CGI does not care why. Now the moment an
-- invoice is sealed, the database asks the invoice-pdf Edge Function to
-- render, store and record it, and to email it to both parties; a sweep every
-- fifteen minutes catches anything that call missed.
--
-- No signed-in user writes the retained copy any more: not the apporteur, who
-- could have filed a doctored one, and not the company either. Only the
-- function, on the service role, through retain_invoice_pdf().

-- ============================================================ the hooks
-- Where the database posts, and the secret it posts with. One row per hook,
-- read only by SECURITY DEFINER functions; no client can see a secret that
-- would let it trigger server work. (push_config predates this and keeps its
-- own table.)
create table edge_hooks (
  name       text primary key,
  url        text not null,
  secret     text not null,
  enabled    boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table edge_hooks enable row level security;
revoke all on edge_hooks from authenticated, anon;

comment on table edge_hooks is
  'Edge Function endpoints the database calls, with their shared secrets. '
  'Read only by SECURITY DEFINER functions; never exposed to clients.';

-- Posts to a hook if it is configured, and does nothing otherwise -- the state
-- a project is in before its functions are deployed. A failed post must never
-- roll back what caused it.
create or replace function public.call_edge_hook(p_name text, p_body jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_hook edge_hooks%rowtype;
begin
  select * into v_hook from edge_hooks where name = p_name and enabled;
  if not found then
    return false;
  end if;
  perform net.http_post(
    url     := v_hook.url,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-hook-secret', v_hook.secret),
    body    := p_body);
  return true;
exception when others then
  return false;
end;
$$;

-- ===================================================== sealing → render
create or replace function public.request_invoice_pdf()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'signed' and old.status is distinct from 'signed'
     and new.pdf_path is null then
    perform call_edge_hook('invoice-pdf', jsonb_build_object('invoice_id', new.id));
  end if;
  return null;
end;
$$;

create trigger invoices_request_pdf after update of status on invoices
  for each row execute function public.request_invoice_pdf();

-- What the sweep re-requests: sealed, and still without a retained copy.
create or replace function public.invoices_missing_pdf(p_limit int default 20)
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id from invoices
   where status in ('signed', 'paid') and pdf_path is null
   order by updated_at
   limit least(greatest(p_limit, 1), 100);
$$;

create or replace function public.request_missing_invoice_pdfs()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_n  int := 0;
begin
  for v_id in select * from invoices_missing_pdf(20) loop
    if call_edge_hook('invoice-pdf', jsonb_build_object('invoice_id', v_id)) then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;

-- ================================================= the function's writes
-- Records the retained file, once. The path is the invoice's own name and the
-- digest is of the bytes the function rendered and stored; a second call
-- returns the file already kept rather than replacing it.
create or replace function public.retain_invoice_pdf(
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
  select * into v_inv from invoices where id = p_invoice_id for update;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  if v_inv.status not in ('signed', 'paid') then
    raise exception 'invoice % is not signed yet', v_inv.number using errcode = '42501';
  end if;
  if v_inv.pdf_path is not null then
    return v_inv.pdf_path;
  end if;
  if p_path is distinct from p_invoice_id::text || '.pdf'
     or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'a retained document is stored as <invoice id>.pdf with its sha256'
      using errcode = '22023';
  end if;

  update invoices set pdf_path = p_path, pdf_sha256 = p_sha256, updated_at = now()
   where id = p_invoice_id;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (null, 'invoices', p_invoice_id, 'pdf_retained',
          jsonb_build_object('path', p_path, 'sha256', p_sha256, 'by', 'invoice-pdf'));
  return p_path;
end;
$$;

-- Who receives the signed PDF: the apporteur, and the company's billing
-- address. A deleted account's placeholder address is not a recipient.
alter table billing_settings add column email text;

create or replace function public.invoice_mail_recipients(p_invoice_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'number', i.number,
    'kind', case when i.corrects_invoice_id is null then 'invoice' else 'credit_note' end,
    'apporteur_name', (i.apporteur_snapshot ->> 'first_name'),
    'apporteur_email', nullif(case when p.email like 'deleted+%@invalid' then null
                                   else p.email end, ''),
    'company_email', (select nullif(email, '') from billing_settings)
  )
  from invoices i
  join profiles p on p.id = i.apporteur_id
  where i.id = p_invoice_id;
$$;

-- These four are the function's alone.
revoke execute on function public.retain_invoice_pdf(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.invoices_missing_pdf(int) from public, anon, authenticated;
revoke execute on function public.invoice_mail_recipients(uuid) from public, anon, authenticated;
revoke execute on function public.request_missing_invoice_pdfs() from public, anon, authenticated;
revoke execute on function public.call_edge_hook(text, jsonb) from public, anon, authenticated;
grant execute on function public.retain_invoice_pdf(uuid, text, text) to service_role;
grant execute on function public.invoices_missing_pdf(int) to service_role;
grant execute on function public.invoice_mail_recipients(uuid) to service_role;
grant execute on function public.request_missing_invoice_pdfs() to service_role;
grant execute on function public.call_edge_hook(text, jsonb) to service_role;

-- ======================================== nobody signed in writes it now
drop policy if exists invoice_pdf_write on storage.objects;
drop function if exists public.record_invoice_pdf(uuid, text, text);

-- ================================================================ sweep
-- pg_cron ships with Supabase; a plain Postgres (the test harness) has none,
-- and then the trigger above is the only path, which the tests exercise.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('invoice-pdf-sweep', '*/15 * * * *',
                          'select public.request_missing_invoice_pdfs()');
  end if;
exception when others then
  raise notice 'pg_cron unavailable: the invoice PDF sweep is not scheduled';
end $$;
