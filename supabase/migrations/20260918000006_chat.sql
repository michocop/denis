-- Energy Courtage — what the chat list actually needs.
--
-- The list was reading the threads table directly, which gives a row with no
-- name on it, no last message and no unread count -- so it rendered
-- "Conversation" and "Aucun message" for everything. This is the read model
-- behind it.

-- A conversation needs names on it, and an apporteur can only see their own
-- row in profiles. The tempting fix -- widen profiles_select so participants
-- can read each other -- leaks: member_overview is a security_invoker view
-- over profiles, so any apporteur who had ever messaged an admin would start
-- seeing that admin in the members list. The exposure belongs to chat, so it
-- is scoped to chat: these two functions hand out a display name and nothing
-- else, and only to someone already in the conversation.
create or replace function public.chat_display_name(p_profile_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.first_name || ' ' || p.last_name
    from profiles p
   where p.id = p_profile_id
     and (
       p.id = (select auth.uid())
       or is_admin((select auth.uid()))
       or exists (
         select 1
           from thread_participants mine
           join thread_participants theirs on theirs.thread_id = mine.thread_id
          where mine.profile_id = (select auth.uid())
            and theirs.profile_id = p.id
       )
     );
$$;

-- Who the conversation is WITH, from the reader's point of view: a direct
-- thread has no title, and showing the participant list would be wrong for
-- the one person who is in every conversation -- yourself.
create or replace function public.thread_counterpart_name(p_thread_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select string_agg(p.first_name || ' ' || p.last_name, ', ' order by p.first_name)
    from thread_participants other
    join profiles p on p.id = other.profile_id
   where other.thread_id = p_thread_id
     and other.profile_id <> (select auth.uid())
     and is_thread_participant(p_thread_id, (select auth.uid()));
$$;

create view thread_overview with (security_invoker = true) as
select
  t.id,
  t.kind,
  t.title,
  t.recommendation_id,
  t.created_at,
  me.pinned,
  me.archived,
  me.last_read_at,
  coalesce(t.title, thread_counterpart_name(t.id), 'Conversation') as counterpart_name,
  (select m.body from messages m
    where m.thread_id = t.id order by m.created_at desc, m.id desc limit 1) as last_message,
  (select m.created_at from messages m
    where m.thread_id = t.id order by m.created_at desc, m.id desc limit 1) as last_message_at,
  (select count(*) from messages m
    where m.thread_id = t.id
      and m.sender_id <> me.profile_id
      and (me.last_read_at is null or m.created_at > me.last_read_at))::int as unread_count
from threads t
join thread_participants me on me.thread_id = t.id and me.profile_id = (select auth.uid());

grant select on thread_overview to authenticated;

-- Messages with their author's name attached. Without it every bubble in the
-- conversation was anonymous. The name comes from the function rather than a
-- join on profiles, because that join would drop every message an apporteur
-- could not resolve a name for -- which is all of an admin's.
create view message_feed with (security_invoker = true) as
select
  m.id,
  m.thread_id,
  m.sender_id,
  chat_display_name(m.sender_id) as sender_name,
  m.body,
  m.attachment_path,
  m.created_at
from messages m;

grant select on message_feed to authenticated;

create index thread_participants_thread_idx on thread_participants (thread_id);

-- Pinning and archiving are per reader, which is why they live on the
-- participant row rather than on the thread.
create or replace function public.set_thread_flags(
  p_thread_id uuid,
  p_pinned    boolean default null,
  p_archived  boolean default null
)
returns void
language sql
as $$
  update thread_participants
     set pinned   = coalesce(p_pinned, pinned),
         archived = coalesce(p_archived, archived)
   where thread_id = p_thread_id and profile_id = (select auth.uid());
$$;

-- Starting a conversation from the apporteur's side: they do not know which
-- admin to write to, and should not have to.
create or replace function public.start_support_thread()
returns uuid
language plpgsql
as $$
declare v_admin uuid := support_admin_id();
begin
  if v_admin is null then
    raise exception 'no administrator is available' using errcode = 'P0002';
  end if;
  return start_direct_thread(v_admin);
end;
$$;
