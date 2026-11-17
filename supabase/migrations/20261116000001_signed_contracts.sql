-- =================================================== the signed-contracts book
-- The energy contracts the company has signed for its clients, typed in by
-- hand, so that every renewal is seen coming (soonest échéance first) and the
-- termination letter to the previous supplier is written from what is stored
-- rather than retyped.
--
-- Not every admin: the book is the owner's. Access is a list of profiles
-- (contract_book_members) that only the database owner edits -- there is no
-- policy on it at all, so no API call, not even an admin's, can add itself.
-- Granting it is one SQL statement, run by hand:
--   insert into contract_book_members (profile_id) values ('<uuid>');

create table contract_book_members (
  profile_id uuid primary key references profiles(id) on delete cascade,
  granted_at timestamptz not null default now()
);
alter table contract_book_members enable row level security;
revoke all on contract_book_members from anon, authenticated;

-- Membership and an active account: a suspended owner reads nothing.
create or replace function public.has_contract_book()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from contract_book_members m
      join profiles p on p.id = m.profile_id
     where m.profile_id = auth.uid() and p.status = 'active'
  );
$$;
grant execute on function public.has_contract_book() to authenticated;

create table signed_contracts (
  id                        uuid primary key default gen_random_uuid(),
  created_by                uuid references profiles(id) on delete set null default auth.uid(),
  -- the client
  client_kind               text not null default 'professionnel'
                              check (client_kind in ('particulier', 'professionnel')),
  client_name               text not null check (char_length(btrim(client_name)) between 1 and 200),
  signatory_name            text check (char_length(signatory_name) <= 200),
  signatory_title           text check (char_length(signatory_title) <= 100),
  siret                     text check (char_length(siret) <= 20),
  phone                     text check (char_length(phone) <= 40),
  email                     text check (char_length(email) <= 200),
  address                   text check (char_length(address) <= 300),
  postal_code               text check (char_length(postal_code) <= 10),
  city                      text check (char_length(city) <= 100),
  -- the site supplied, when it is not the postal address
  site_address              text check (char_length(site_address) <= 300),
  -- what is supplied
  energy                    text not null default 'electricite'
                              check (energy in ('electricite', 'gaz')),
  delivery_point            text check (char_length(delivery_point) <= 40),
  -- the contract being left
  previous_supplier         text check (char_length(previous_supplier) <= 200),
  previous_supplier_address text check (char_length(previous_supplier_address) <= 400),
  previous_reference        text check (char_length(previous_reference) <= 100),
  termination_on            date,
  -- the contract signed
  new_supplier              text check (char_length(new_supplier) <= 200),
  signed_on                 date,
  starts_on                 date,
  ends_on                   date,
  notes                     text check (char_length(notes) <= 4000),
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  constraint signed_contracts_period check (ends_on is null or starts_on is null or ends_on >= starts_on)
);

create index signed_contracts_ends_on on signed_contracts (ends_on);

create trigger signed_contracts_touch before update on signed_contracts
  for each row execute function public.touch_updated_at();

alter table signed_contracts enable row level security;
revoke all on signed_contracts from anon;
grant select, insert, update, delete on signed_contracts to authenticated;

create policy signed_contracts_owner on signed_contracts for all to authenticated
  using ((select has_contract_book()))
  with check ((select has_contract_book()));
