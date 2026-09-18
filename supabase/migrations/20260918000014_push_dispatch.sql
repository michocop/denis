-- Energy Courtage — handing a notification to the push sender.
--
-- The row already exists and already carries the rendered title and body. What
-- was missing is the step that tells Apple about it. That happens here, from a
-- trigger, so it fires however the notification came to exist -- a stage
-- advanced from the app, from the console, or by a script.
--
-- Configuration lives in a table rather than in the function body, because
-- putting a URL and a secret inside a migration would commit them to the
-- repository. Until a row exists the trigger is INERT: it returns without
-- doing anything, rather than raising on every insert and making the whole app
-- fail because push is not set up yet. That is the state the project ships in.

create table push_config (
  id            boolean primary key default true,
  function_url  text not null,
  hook_secret   text not null,
  enabled       boolean not null default true,
  updated_at    timestamptz not null default now(),
  constraint push_config_singleton check (id)
);

alter table push_config enable row level security;

-- Deliberately no policy for `authenticated`. The secret in here would let
-- anyone who could read it push arbitrary text to every apporteur's lock
-- screen, and no screen in the app needs it: only the trigger does, and that
-- runs as the definer.
comment on table push_config is
  'Read only by SECURITY DEFINER triggers. Never exposed to the client: the '
  'hook secret would let its holder push anything to anyone.';

-- pg_net posts without blocking the transaction. A push that is slow, or an
-- Apple outage, must not make advancing a stage time out.
--
-- Supabase ships it; a plain Postgres does not, and the test harness runs on
-- one. Missing, the trigger below simply finds no configuration and does
-- nothing -- which is also the state a project is in before push is set up,
-- so it is a path worth having rather than a special case.
do $$
begin
  create extension if not exists pg_net;
exception when others then
  raise notice 'pg_net unavailable: push dispatch will be inert until it is installed';
end $$;

create or replace function public.dispatch_push_notification()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_config push_config%rowtype;
begin
  select * into v_config from push_config where enabled;
  if not found then
    -- push is not configured; the in-app notification still exists
    return null;
  end if;

  perform net.http_post(
    url     := v_config.function_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-hook-secret', v_config.hook_secret),
    body    := jsonb_build_object('record', jsonb_build_object(
                 'id',                new.id,
                 'profile_id',        new.profile_id,
                 'kind',              new.kind,
                 'title',             notification_title(new.kind, new.payload),
                 'body',              notification_body(new.kind, new.payload),
                 'thread_id',         new.payload ->> 'thread_id',
                 'recommendation_id', new.payload ->> 'recommendation_id',
                 'invoice_id',        new.payload ->> 'invoice_id'))
  );
  return null;
exception when others then
  -- A failed push must never roll back the thing that caused it. The row is
  -- in the table and the app will show it on next read; losing the stage
  -- advance because Apple was unreachable would be far worse.
  return null;
end;
$$;

create trigger notifications_dispatch_push after insert on notifications
  for each row execute function public.dispatch_push_notification();
