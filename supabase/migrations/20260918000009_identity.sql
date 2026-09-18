-- Energy Courtage — asking the database who you are.
--
-- The client worked out its own identity by reading `profiles` with
-- `limit 1` and taking the first row, on the reasoning that RLS narrows
-- profiles to the caller. That is true for an apporteur and false for an
-- admin, whose policy lets them read everyone: an administrator asking who
-- they were got back whichever profile the planner returned first --
-- in the seed, Johann.
--
-- What that produced:
--   * the Profil screen showed an admin somebody else's name, email, phone,
--     SIRET and mandate status, and saving it wrote to that person's row;
--   * signing the self-billing mandate signed it for the wrong apporteur;
--   * sending a message stamped sender_id with the wrong person, which RLS
--     refused outright -- the only reason this surfaced at all.
--
-- "limit 1" is not an identity. auth.uid() is, so these ask for it directly
-- and there is no longer a shape in the client that depends on a policy
-- happening to narrow a table to one row.

create or replace function public.current_profile_id()
returns uuid
language sql
stable
as $$
  select auth.uid();
$$;

create or replace function public.my_profile()
returns profiles
language sql
stable
as $$
  select * from profiles where id = auth.uid();
$$;
