-- Energy Courtage — documents on a lead.
--
-- trinity-energie.fr's whole pitch is "send us your bill", and the app had no
-- way to send anything: `documents` was admin-write only and had no bucket
-- behind it. Now the apporteur attaches the filleul's energy bill (a scan, a
-- photo, a PDF) to the recommendation, and the company attaches quotes and
-- contracts. Who can see a file is exactly who can see the lead.
--
-- Files live in a private bucket at <recommendation id>/<random id>.<ext>, so
-- the lead a file belongs to is in its name and the policies can derive
-- access from it, the same way the invoices bucket does.

-- The bill the filleul pays today: what the brokerage works from.
alter type document_type add value if not exists 'energy_bill';

alter table documents add column mime_type text;

insert into storage.buckets (id, name, public)
values ('documents', 'documents', false)
on conflict (id) do nothing;

-- Hosted Storage enforces these before a byte is stored; the local stand-in
-- has no such columns, and the RPC below checks them again regardless.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'storage' and table_name = 'buckets'
                and column_name = 'allowed_mime_types') then
    update storage.buckets
       set file_size_limit = 10 * 1024 * 1024,
           allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/heic']
     where id = 'documents';
  end if;
end $$;

-- The lead an object belongs to, or null for a name that is not ours. Never
-- raises: a policy that errors on a malformed name refuses the whole query.
create or replace function public.document_recommendation_id(p_name text)
returns uuid
language sql
immutable
as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f-]{36}\.(pdf|jpe?g|png|heic)$'
    then split_part(p_name, '/', 1)::uuid
  end;
$$;

-- Whether the caller may see the lead -- the rule reco_select applies -- asked
-- from a policy on another table, so it runs as definer to avoid recursion.
create or replace function public.can_access_recommendation(p_recommendation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_recommendation_id is not null and exists (
    select 1 from recommendations r
     where r.id = p_recommendation_id
       and ((r.parrain_id = auth.uid() and r.deleted_at is null) or is_admin(auth.uid()))
  );
$$;

drop policy if exists documents_read on storage.objects;
create policy documents_read on storage.objects for select to authenticated
  using (bucket_id = 'documents'
         and can_access_recommendation(document_recommendation_id(storage.objects.name)));

drop policy if exists documents_upload on storage.objects;
create policy documents_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'documents'
              and (select is_active_member((select auth.uid())))
              and can_access_recommendation(document_recommendation_id(storage.objects.name)));

-- Storage records who uploaded each object in `owner`.
drop policy if exists documents_remove on storage.objects;
create policy documents_remove on storage.objects for delete to authenticated
  using (bucket_id = 'documents'
         and (owner = (select auth.uid()) or (select is_admin((select auth.uid())))));

-- ---------------------------------------------------------- registering
-- The row that makes an uploaded file part of the lead. Checked here rather
-- than trusted from the client: the file must really be in the bucket, under
-- this lead's name, of an accepted type and size, and an apporteur may only
-- file bills and other papers -- quotes, contracts and invoices are the
-- company's to attach.
create or replace function public.register_document(
  p_recommendation_id uuid,
  p_path              text,
  p_filename          text,
  p_byte_size         bigint,
  p_mime_type         text,
  p_kind              text default 'energy_bill'
)
returns documents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := auth.uid();
  v_kind document_type;
  v_name text;
  v_doc  documents%rowtype;
begin
  if v_uid is null or not is_active_member(v_uid) then
    raise exception 'only an active member can add a document' using errcode = '42501';
  end if;
  if not can_access_recommendation(p_recommendation_id) then
    raise exception 'recommendation not found' using errcode = 'P0002';
  end if;
  if document_recommendation_id(p_path) is distinct from p_recommendation_id then
    raise exception 'a document is stored as <recommendation id>/<id>.<pdf|jpg|png|heic>'
      using errcode = '22023';
  end if;
  if not exists (select 1 from storage.objects
                  where bucket_id = 'documents' and name = p_path) then
    raise exception 'the file has not been uploaded' using errcode = 'P0002';
  end if;
  if p_mime_type not in ('application/pdf', 'image/jpeg', 'image/png', 'image/heic') then
    raise exception 'only PDF and photos are accepted' using errcode = '22023';
  end if;
  if p_byte_size is null or p_byte_size <= 0 or p_byte_size > 10 * 1024 * 1024 then
    raise exception 'a document is at most 10 MB' using errcode = '22023';
  end if;

  begin
    v_kind := p_kind::document_type;
  exception when invalid_text_representation then
    raise exception 'unknown document kind %', p_kind using errcode = '22023';
  end;
  if not is_admin(v_uid) and v_kind::text not in ('energy_bill', 'other') then
    raise exception 'quotes, contracts and invoices are attached by the company'
      using errcode = '42501';
  end if;

  -- what is shown and offered on download; never a path
  v_name := left(btrim(regexp_replace(coalesce(p_filename, ''), '[/\\\r\n]', '-', 'g')), 120);
  if v_name = '' then
    v_name := 'document';
  end if;

  insert into documents (recommendation_id, kind, storage_path, filename, byte_size,
                         uploaded_by, mime_type)
  values (p_recommendation_id, v_kind, p_path, v_name, p_byte_size, v_uid, p_mime_type)
  returning * into v_doc;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_uid, 'documents', v_doc.id, 'register_document',
          jsonb_build_object('recommendation_id', p_recommendation_id, 'kind', v_kind));
  return v_doc;
end;
$$;

-- Taking one back: the person who added it, the same day, or the company.
-- The bytes are removed through the Storage API (documents_remove above);
-- this removes the row that lists them.
create or replace function public.remove_document(p_document_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_doc documents%rowtype;
begin
  select * into v_doc from documents where id = p_document_id;
  if not found or not can_access_recommendation(v_doc.recommendation_id) then
    raise exception 'document not found' using errcode = 'P0002';
  end if;
  if not is_admin(v_uid)
     and not (v_doc.uploaded_by = v_uid and v_doc.created_at > now() - interval '24 hours') then
    raise exception 'a document can be removed by the person who added it, the same day'
      using errcode = '42501';
  end if;

  delete from documents where id = p_document_id;
  insert into audit_log (actor_id, entity, entity_id, action, before)
  values (v_uid, 'documents', p_document_id, 'remove_document', to_jsonb(v_doc));
  return v_doc.storage_path;
end;
$$;

-- functions added here follow the rule set in 20260930000001
revoke execute on function public.document_recommendation_id(text) from public, anon;
revoke execute on function public.can_access_recommendation(uuid) from public, anon;
revoke execute on function public.register_document(uuid, text, text, bigint, text, text) from public, anon;
revoke execute on function public.remove_document(uuid) from public, anon;
grant execute on function public.document_recommendation_id(text) to authenticated, service_role;
grant execute on function public.can_access_recommendation(uuid) to authenticated, service_role;
grant execute on function public.register_document(uuid, text, text, bigint, text, text) to authenticated, service_role;
grant execute on function public.remove_document(uuid) to authenticated, service_role;

-- The local stand-in grants only select and insert on storage.objects;
-- hosted Supabase already grants delete, and owns the table as another role.
do $$
begin
  grant delete on storage.objects to authenticated;
exception when others then
  null;
end $$;
