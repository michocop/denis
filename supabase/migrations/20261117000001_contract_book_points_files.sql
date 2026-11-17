-- ============================== the contracts book: many meters, and files
-- A client is rarely one meter: a company signs for several sites, power and
-- gas, each with its own PDL/PRM or PCE. The one meter a contract had becomes
-- a list -- as long as needed -- of {id, energy, number, label, site}.
--
-- And the papers go with the contract: the signed contract, the bills, the
-- client's ID, as PDFs or photos, in a private bucket only the book's members
-- can read.

alter table signed_contracts
  add column delivery_points jsonb not null default '[]'::jsonb
    constraint signed_contracts_points_list
    check (jsonb_typeof(delivery_points) = 'array' and jsonb_array_length(delivery_points) <= 500);

-- What was typed in the single fields becomes the first point of the list.
update signed_contracts
   set delivery_points = jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
         'id', gen_random_uuid(), 'energy', energy, 'number', coalesce(delivery_point, ''),
         'site', site_address)))
 where delivery_point is not null or site_address is not null;

alter table signed_contracts
  drop column delivery_point,
  drop column site_address,
  drop column energy;

-- ------------------------------------------------------------------ files
create table signed_contract_files (
  id           uuid primary key default gen_random_uuid(),
  contract_id  uuid not null references signed_contracts(id) on delete cascade,
  storage_path text not null unique,
  filename     text not null check (char_length(filename) between 1 and 255),
  byte_size    bigint,
  mime_type    text,
  created_at   timestamptz not null default now()
);
create index signed_contract_files_contract on signed_contract_files (contract_id, created_at);

alter table signed_contract_files enable row level security;
revoke all on signed_contract_files from anon;
grant select, insert, update, delete on signed_contract_files to authenticated;

create policy signed_contract_files_owner on signed_contract_files for all to authenticated
  using ((select has_contract_book()))
  with check ((select has_contract_book()));

insert into storage.buckets (id, name, public)
values ('contract-book', 'contract-book', false)
on conflict (id) do nothing;

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'storage' and table_name = 'buckets'
                and column_name = 'allowed_mime_types') then
    update storage.buckets
       set file_size_limit = 10 * 1024 * 1024,
           allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/heic']
     where id = 'contract-book';
  end if;
end $$;

drop policy if exists contract_book_read on storage.objects;
create policy contract_book_read on storage.objects for select to authenticated
  using (bucket_id = 'contract-book' and (select has_contract_book()));

drop policy if exists contract_book_upload on storage.objects;
create policy contract_book_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'contract-book' and (select has_contract_book()));

drop policy if exists contract_book_remove on storage.objects;
create policy contract_book_remove on storage.objects for delete to authenticated
  using (bucket_id = 'contract-book' and (select has_contract_book()));
