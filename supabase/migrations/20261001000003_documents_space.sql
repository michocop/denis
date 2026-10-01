-- Energy Courtage — "Mes documents", and who an apporteur's contact is.
--
-- Three things the Profil screen of the real app shows and this one could not:
--   * "Contact de Michel AJ": the admin who invited this person;
--   * "Fichiers": every reconnaissance d'honoraires (and avoir) issued to them;
--   * "Mes justificatifs — Supprimés après 30 jours": an identity card and a
--     RIB, sent so the company can check who it pays and where.
--
-- The justificatifs are the most sensitive files in the system, so they get a
-- bucket of their own, a folder per person, and a lifetime: thirty days after
-- upload the row goes and the purge-justificatifs function deletes the file.
-- The company records what it needed (bank_details_on_file) before then.

-- ------------------------------------------------------------- the contact
create or replace function public.my_contact_name()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.first_name || ' ' || p.last_name
    from invites i
    join profiles p on p.id = i.created_by
   where i.used_by = auth.uid()
   order by i.used_at desc nulls last
   limit 1;
$$;

grant execute on function public.my_contact_name() to authenticated;

-- ---------------------------------------------------------------- the files
-- Security invoker: RLS on invoices decides what each caller sees -- their
-- own for an apporteur, everything for the company.
create or replace function public.my_documents()
returns table (
  invoice_id         uuid,
  number             text,
  kind               text,      -- 'honoraires' | 'avoir'
  status             invoice_status,
  amount_ttc         numeric,
  issued_at          timestamptz,
  filleul_name       text,
  apporteur_name     text,
  recommendation_active boolean,
  has_pdf            boolean
)
language sql
stable
as $$
  select i.id,
         i.number,
         case when i.corrects_invoice_id is null then 'honoraires' else 'avoir' end,
         i.status,
         i.amount_ttc,
         i.created_at,
         r.filleul_first_name || ' ' || r.filleul_last_name,
         p.first_name || ' ' || p.last_name,
         r.status = 'active',
         i.pdf_path is not null
    from invoices i
    join recommendations r on r.id = i.recommendation_id
    join profiles p on p.id = i.apporteur_id
   where i.status <> 'void'
   order by i.created_at desc;
$$;

grant execute on function public.my_documents() to authenticated;

-- --------------------------------------------------------- the justificatifs
create type justificatif_kind as enum ('carte_identite', 'rib');

create table justificatifs (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null references profiles(id) on delete cascade,
  kind         justificatif_kind not null,
  storage_path text not null unique,
  filename     text not null,
  byte_size    bigint,
  uploaded_at  timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '30 days'
);

create index justificatifs_owner_idx on justificatifs (profile_id, kind, uploaded_at desc);
create index justificatifs_expiry_idx on justificatifs (expires_at);

alter table justificatifs enable row level security;

create policy justificatifs_read on justificatifs for select to authenticated
  using (profile_id = auth.uid() or is_admin(auth.uid()));
grant select on justificatifs to authenticated;
-- writes go through record_justificatif only

insert into storage.buckets (id, name, public)
values ('justificatifs', 'justificatifs', false)
on conflict (id) do nothing;

-- Files live under <profile id>/..., and only that person may put one there.
drop policy if exists justificatifs_upload on storage.objects;
create policy justificatifs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'justificatifs'
              and split_part(name, '/', 1) = auth.uid()::text);

-- The owner sees their own; the company sees all, which is the point of sending them.
drop policy if exists justificatifs_download on storage.objects;
create policy justificatifs_download on storage.objects for select to authenticated
  using (bucket_id = 'justificatifs'
         and (split_part(name, '/', 1) = auth.uid()::text or is_admin(auth.uid())));

-- Records an uploaded file. A new one replaces the previous of the same kind
-- at once: the old file is expired now rather than kept for its 30 days.
create or replace function public.record_justificatif(
  p_kind      justificatif_kind,
  p_path      text,
  p_filename  text,
  p_byte_size bigint default null
)
returns justificatifs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_row justificatifs%rowtype;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if split_part(coalesce(p_path, ''), '/', 1) <> v_uid::text or p_path like '%..%' then
    raise exception 'a file can only be recorded from your own folder' using errcode = '42501';
  end if;
  if coalesce(p_byte_size, 0) > 10 * 1024 * 1024 then
    raise exception 'Fichier trop lourd (10 Mo maximum).' using errcode = '22023';
  end if;

  update justificatifs set expires_at = now()
   where profile_id = v_uid and kind = p_kind and expires_at > now();

  insert into justificatifs (profile_id, kind, storage_path, filename, byte_size)
  values (v_uid, p_kind, p_path, left(coalesce(nullif(btrim(p_filename), ''), 'document'), 120), p_byte_size)
  returning * into v_row;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_uid, 'justificatifs', v_row.id, 'upload', jsonb_build_object('kind', p_kind));

  return v_row;
end;
$$;

revoke all on function public.record_justificatif(justificatif_kind, text, text, bigint) from public, anon;
grant execute on function public.record_justificatif(justificatif_kind, text, text, bigint) to authenticated;

-- What the screen lists: the live one of each kind, with when it will go.
create or replace view my_justificatifs
with (security_invoker = true) as
select distinct on (kind) id, kind, filename, uploaded_at, expires_at, storage_path
  from justificatifs
 where profile_id = auth.uid() and expires_at > now()
 order by kind, uploaded_at desc;

grant select on my_justificatifs to authenticated;

-- ------------------------------------------------------------------ purging
-- Called by the purge-justificatifs function (service role), which deletes
-- the files through the Storage API and then these rows. Returned rather than
-- deleted here because a file must not outlive its row unnoticed: the row is
-- only removed once the file is confirmed gone.
create or replace function public.expired_justificatifs()
returns table (id uuid, storage_path text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id, storage_path from justificatifs where expires_at <= now();
$$;

revoke all on function public.expired_justificatifs() from public, anon, authenticated;

create or replace function public.forget_justificatif(p_id uuid)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from justificatifs where id = p_id and expires_at <= now();
$$;

revoke all on function public.forget_justificatif(uuid) from public, anon, authenticated;

do $$
begin
  grant execute on function public.expired_justificatifs() to service_role;
  grant execute on function public.forget_justificatif(uuid) to service_role;
exception when undefined_object then
  null;  -- plain Postgres without the Supabase roles
end $$;
