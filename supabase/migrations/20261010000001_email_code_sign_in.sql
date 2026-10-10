-- Energy Courtage — sign-in by emailed code.
--
-- The app no longer has passwords: it asks for the address, Auth emails a
-- six-digit code, and the code signs in. Auth will not send that code to an
-- address that was never confirmed while sign-up is closed -- and accounts
-- opened by the old invitation link stayed unconfirmed until the link was
-- opened, which Brevo's click tracking broke. send-invite now opens accounts
-- confirmed; this confirms the ones already waiting.
--
-- Safe: an account only exists because an admin invited that address, and
-- the code, sent to it, proves the address at every sign-in.
-- (The local test database's auth shim has no such column: nothing to do.)
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users'
                and column_name = 'email_confirmed_at') then
    execute $q$
      update auth.users u
         set email_confirmed_at = now()
       where u.email_confirmed_at is null
         and exists (select 1 from public.invites i
                      where lower(i.email) = lower(u.email)
                        and i.used_at is null
                        and i.expires_at > now())
    $q$;
  end if;
end $$;
