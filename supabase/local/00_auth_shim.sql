-- LOCAL ONLY. Supabase already provides auth.users, auth.uid() and the
-- authenticated/anon/service_role roles. This file recreates just enough of
-- them to run the migrations and the RLS tests against a plain Postgres,
-- and must never be applied to a real Supabase project.

create extension if not exists pgcrypto;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end $$;

create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text unique
);

-- Same implementation Supabase uses: the user id comes from the request's JWT.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(
           nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub',
           ''
         )::uuid;
$$;

grant usage on schema auth to authenticated, anon;

-- Storage, in the same spirit: Supabase provides storage.buckets and
-- storage.objects with RLS on objects. The invoice PDF policies are written
-- against them, and a policy nothing can execute is a policy nobody has
-- checked -- so the tests get a table shaped like the real one.
create schema if not exists storage;

create table if not exists storage.buckets (
  id     text primary key,
  name   text not null,
  public boolean not null default false
);

create table if not exists storage.objects (
  id        uuid primary key default gen_random_uuid(),
  bucket_id text not null references storage.buckets(id),
  name      text not null,
  owner     uuid,
  created_at timestamptz not null default now(),
  unique (bucket_id, name)
);

alter table storage.objects enable row level security;

grant usage on schema storage to authenticated, anon;
grant select, insert on storage.objects to authenticated;
grant select on storage.buckets to authenticated;
