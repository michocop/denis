-- LOCAL / CI ONLY. Supabase provisions these itself; this recreates just
-- enough of that setup for a real PostgREST to sit in front of the schema so
-- the iOS client can be exercised against it rather than against a mock.

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login password 'postgres';
  end if;
end $$;

-- PostgREST connects as the authenticator and switches into the role named by
-- the JWT, which is how RLS ends up seeing a real user.
grant anon, authenticated, service_role to authenticator;

grant usage on schema public, auth to anon, authenticated;
grant select on all tables in schema public to anon;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
-- Function grants in public are the migrations' business, not this file's:
-- 20260930000001 revokes them from anon and keeps next_invoice_index() away
-- from everyone. Granting them here, after the migrations, would have the
-- integration tests run against a looser database than production.
grant execute on all functions in schema auth to anon, authenticated;
