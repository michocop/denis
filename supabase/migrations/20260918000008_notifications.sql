-- Energy Courtage — notifications people can actually receive.
--
-- The table and one trigger existed: advancing a stage wrote a row, and
-- nothing in the app ever read it. Nothing at all was written for a message
-- or for an invoice waiting on a signature, which are the two things that
-- most need chasing.
--
-- The text is rendered here rather than in Swift because a push notification
-- is composed server-side, and two renderers drift: the banner on the lock
-- screen would stop matching the row in the list.

-- ------------------------------------------------------------ new triggers
create or replace function public.notify_on_message()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into notifications (profile_id, kind, payload)
  select p.profile_id, 'message_received',
         jsonb_build_object(
           'thread_id', new.thread_id,
           'message_id', new.id,
           'sender', (select first_name || ' ' || last_name
                        from profiles where id = new.sender_id),
           'excerpt', left(coalesce(new.body, 'Pièce jointe'), 140)
         )
    from thread_participants p
   where p.thread_id = new.thread_id
     and p.profile_id <> new.sender_id;
  return null;
end;
$$;

create trigger message_notifies after insert on messages
  for each row execute function public.notify_on_message();

-- An invoice nobody is told about sits unsigned, and an unsigned invoice is
-- an apporteur who does not get paid.
create or replace function public.notify_on_invoice()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into notifications (profile_id, kind, payload)
  values (new.apporteur_id, 'invoice_ready',
          jsonb_build_object(
            'invoice_id', new.id,
            'number', new.number,
            'amount', to_char(new.amount_ttc, 'FM999999990.00'),
            'currency', new.currency
          ));
  return null;
end;
$$;

create trigger invoice_notifies after insert on invoices
  for each row execute function public.notify_on_invoice();

-- ---------------------------------------------------------------- the text
create or replace function public.notification_title(p_kind text, p_payload jsonb)
returns text
language sql
immutable
as $$
  select case p_kind
    when 'stage_advanced'  then 'Votre recommandation avance'
    when 'reward_earned'   then 'Commission acquise'
    when 'message_received' then coalesce(p_payload ->> 'sender', 'Nouveau message')
    when 'invoice_ready'   then 'Facture à signer'
    when 'payment_sent'    then 'Paiement envoyé'
    else 'Notification'
  end;
$$;

create or replace function public.notification_body(p_kind text, p_payload jsonb)
returns text
language sql
immutable
as $$
  select case p_kind
    when 'stage_advanced' then
      coalesce(p_payload ->> 'filleul', 'Votre filleul') || ' : '
      || coalesce(p_payload ->> 'stage_label', 'étape suivante')
    when 'reward_earned' then
      coalesce(p_payload ->> 'filleul', 'Votre filleul') || ' a signé'
      || coalesce(' — ' || (p_payload ->> 'amount') || ' €', '')
    when 'message_received' then coalesce(p_payload ->> 'excerpt', '')
    when 'invoice_ready' then
      'Facture ' || coalesce(p_payload ->> 'number', '') || ' — '
      || coalesce(p_payload ->> 'amount', '') || ' '
      || coalesce(p_payload ->> 'currency', 'EUR')
    when 'payment_sent' then
      coalesce(p_payload ->> 'amount', '') || ' '
      || coalesce(p_payload ->> 'currency', 'EUR') || ' en route'
    else ''
  end;
$$;

-- The ids are pulled out as typed columns rather than left inside the jsonb,
-- because the client needs them to open the thing the notification is about,
-- and decoding a heterogeneous payload in Swift means either a stringly-typed
-- dictionary that throws on the first number or a custom decoder per kind.
create view notification_feed with (security_invoker = true) as
select
  n.id,
  n.kind,
  notification_title(n.kind, n.payload) as title,
  notification_body(n.kind, n.payload)  as body,
  (n.payload ->> 'thread_id')::uuid         as thread_id,
  (n.payload ->> 'recommendation_id')::uuid as recommendation_id,
  (n.payload ->> 'invoice_id')::uuid        as invoice_id,
  n.read_at,
  n.created_at
from notifications n
where n.profile_id = (select auth.uid());

grant select on notification_feed to authenticated;

-- ------------------------------------------------------- device registration
-- Groundwork for APNs. Nothing sends yet: that needs an Apple push key and a
-- server to hold it, neither of which exists. Recording the token now means
-- the client side is done and switching it on is a key plus a function, not
-- a schema change and an app release.
create table device_tokens (
  id         uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  token      text not null,
  platform   text not null default 'ios',
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (token)
);

alter table device_tokens enable row level security;

create policy device_tokens_own on device_tokens for all to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

create index device_tokens_profile_idx on device_tokens (profile_id);

-- The blanket grant in the RLS migration ran before this table existed, so it
-- needs its own. RLS above is what actually restricts the rows.
grant select, insert, update, delete on device_tokens to authenticated;

-- Re-registering the same device is the normal case, not an error: iOS hands
-- the token back on every launch.
create or replace function public.register_device_token(
  p_token    text,
  p_platform text default 'ios'
)
returns void
language plpgsql
as $$
begin
  insert into device_tokens (profile_id, token, platform)
  values (auth.uid(), p_token, p_platform)
  on conflict (token) do update
    set profile_id = auth.uid(), last_seen_at = now();
end;
$$;

create or replace function public.forget_device_token(p_token text)
returns void
language sql
as $$
  delete from device_tokens where token = p_token and profile_id = auth.uid();
$$;
