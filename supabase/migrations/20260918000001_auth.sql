-- Energy Courtage — invitation-based access.
--
-- This is not a product anyone signs up to: an apporteur is recruited, and the
-- brokerage decides who gets in. So account creation is gated on an invite the
-- company issued, and the invite carries the role -- a client can never ask to
-- be an admin.

create table invites (
  code          text primary key,
  -- when set, only this address may redeem it
  email         text,
  role          user_role not null default 'apporteur',
  -- false when the company wants to vet the person after they register
  auto_activate boolean not null default true,
  created_by    uuid references profiles(id),
  expires_at    timestamptz not null default now() + interval '30 days',
  used_at       timestamptz,
  used_by       uuid references profiles(id),
  created_at    timestamptz not null default now(),
  constraint invite_code_shape check (code ~ '^[A-Z0-9-]{6,32}$')
);

alter table invites enable row level security;

-- Only admins manage invites. Nobody reads the table to check a code: that
-- goes through redeem_invite(), so an invalid attempt cannot tell the caller
-- which codes exist.
create policy invites_admin on invites for all to authenticated
  using (is_admin(auth.uid())) with check (is_admin(auth.uid()));

create or replace function public.create_invite(
  p_email         text default null,
  p_role          user_role default 'apporteur',
  p_auto_activate boolean default true
)
returns invites
language plpgsql
security definer
set search_path = public, pg_temp, extensions
as $$
declare
  v_code   text;
  v_invite invites%rowtype;
begin
  if not is_admin(auth.uid()) then
    raise exception 'only an admin may invite' using errcode = '42501';
  end if;

  -- Readable code, no ambiguous characters: it gets dictated over the phone.
  v_code := translate(upper(substr(encode(gen_random_bytes(8), 'base64'), 1, 10)),
                      '+/=OIL01', 'XYZWMNPQ');

  insert into invites (code, email, role, auto_activate, created_by)
  values (v_code, lower(nullif(p_email, '')), p_role, p_auto_activate, auth.uid())
  returning * into v_invite;

  return v_invite;
end;
$$;

-- Called once, by the freshly registered user, to turn their auth account into
-- a profile. SECURITY DEFINER because at this moment they have no profile and
-- therefore no rights to anything.
create or replace function public.redeem_invite(
  p_code       text,
  p_first_name text,
  p_last_name  text
)
returns profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := auth.uid();
  v_email   text;
  v_invite  invites%rowtype;
  v_profile profiles%rowtype;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if exists (select 1 from profiles where id = v_uid) then
    raise exception 'this account already has a profile' using errcode = '23505';
  end if;

  select email into v_email from auth.users where id = v_uid;

  select * into v_invite from invites
   where code = upper(trim(p_code))
   for update;

  -- One message for every failure: a distinct "expired" or "already used"
  -- would let someone probe the table one code at a time.
  if not found
     or v_invite.used_at is not null
     or v_invite.expires_at < now()
     or (v_invite.email is not null and v_invite.email is distinct from lower(v_email)) then
    raise exception 'invitation invalide ou expirée' using errcode = '22023';
  end if;

  insert into profiles (id, role, status, first_name, last_name, email)
  values (v_uid, v_invite.role,
          case when v_invite.auto_activate then 'active'::profile_status
               else 'pending'::profile_status end,
          trim(p_first_name), trim(p_last_name), v_email)
  returning * into v_profile;

  update invites set used_at = now(), used_by = v_uid where code = v_invite.code;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_uid, 'profiles', v_uid, 'redeem_invite',
          jsonb_build_object('role', v_invite.role));

  return v_profile;
end;
$$;

-- The app calls this on launch to decide what to show: the tabs, the
-- pending-approval screen, or sign-in.
create or replace function public.my_account_state()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when auth.uid() is null then jsonb_build_object('state', 'signed_out')
    when not exists (select 1 from profiles where id = auth.uid())
      then jsonb_build_object('state', 'needs_invite')
    else (
      select jsonb_build_object(
        'state', case status
                   when 'active'    then 'ready'
                   when 'pending'   then 'pending_approval'
                   when 'suspended' then 'suspended'
                 end,
        'role', role,
        'full_name', first_name || ' ' || last_name
      )
      from profiles where id = auth.uid()
    )
  end;
$$;

-- An admin approving someone who registered against a vetting invite.
create or replace function public.approve_member(p_profile_id uuid)
returns profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_profile profiles%rowtype;
begin
  if not is_admin(auth.uid()) then
    raise exception 'only an admin may approve' using errcode = '42501';
  end if;

  update profiles set status = 'active'
   where id = p_profile_id and status = 'pending'
  returning * into v_profile;

  if not found then
    raise exception 'no pending member with that id' using errcode = 'P0002';
  end if;

  insert into audit_log (actor_id, entity, entity_id, action)
  values (auth.uid(), 'profiles', p_profile_id, 'approve_member');
  return v_profile;
end;
$$;
