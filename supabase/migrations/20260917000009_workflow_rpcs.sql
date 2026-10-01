-- Energy Courtage — the operations the app actually calls.
--
-- Everything the UI can do is one function here, so the client never has to
-- know the ordering rules (which stage is first, what archiving implies) and
-- cannot get them wrong.

-- A new recommendation always enters at the first stage. Filling this in the
-- database means the create form does not have to know the pipeline at all.
create or replace function public.default_recommendation_fields()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.current_stage_id is null then
    select id into new.current_stage_id from stages order by position limit 1;
  end if;

  return new;
end;
$$;

alter table recommendations alter column current_stage_id drop not null;
create trigger recos_defaults before insert on recommendations
  for each row execute function public.default_recommendation_fields();

-- NOT NULL is replaced by a constraint that only bites after the trigger,
-- so a client may omit the column but a row can never end up without a stage.
alter table recommendations
  add constraint reco_stage_required check (current_stage_id is not null) not valid;
alter table recommendations validate constraint reco_stage_required;

-- ------------------------------------------------------- admin operations

create or replace function public.reassign_recommendation(
  p_recommendation_id uuid,
  p_admin_id          uuid
)
returns recommendations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_reco recommendations%rowtype;
begin
  if not is_admin(auth.uid()) then
    raise exception 'only an admin may reassign' using errcode = '42501';
  end if;
  if not is_admin(p_admin_id) then
    raise exception 'a recommendation can only be assigned to an administrator'
      using errcode = '22023';
  end if;

  update recommendations set assigned_admin_id = p_admin_id
   where id = p_recommendation_id and deleted_at is null
  returning * into v_reco;

  if not found then
    raise exception 'recommendation not found' using errcode = 'P0002';
  end if;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (auth.uid(), 'recommendations', p_recommendation_id, 'reassign',
          jsonb_build_object('assigned_admin_id', p_admin_id));
  return v_reco;
end;
$$;

create or replace function public.archive_recommendation(
  p_recommendation_id uuid,
  p_won               boolean
)
returns recommendations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_reco recommendations%rowtype;
begin
  if not is_admin(auth.uid()) then
    raise exception 'only an admin may archive' using errcode = '42501';
  end if;

  update recommendations
     set status      = case when p_won then 'archived_won'::reco_status
                           else 'archived_lost'::reco_status end,
         archived_at = now(),
         -- a lost deal cancels a reward that has not yet been invoiced
         reward_status = case
           when not p_won and reward_status in ('pending','earned') then 'cancelled'::reward_status
           else reward_status
         end
   where id = p_recommendation_id and deleted_at is null
  returning * into v_reco;

  if not found then
    raise exception 'recommendation not found' using errcode = 'P0002';
  end if;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (auth.uid(), 'recommendations', p_recommendation_id, 'archive',
          jsonb_build_object('won', p_won));
  return v_reco;
end;
$$;

-- "Supprimer" in the action sheet. Always a soft delete: an invoice may exist
-- now or later, and a deleted row would orphan it.
create or replace function public.soft_delete_recommendation(p_recommendation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_admin(auth.uid()) then
    raise exception 'only an admin may delete' using errcode = '42501';
  end if;

  update recommendations set deleted_at = now()
   where id = p_recommendation_id and deleted_at is null;

  insert into audit_log (actor_id, entity, entity_id, action)
  values (auth.uid(), 'recommendations', p_recommendation_id, 'soft_delete');
end;
$$;

-- ------------------------------------------------------------- signatures
-- The signer is always the caller and the role is derived from who they are,
-- so no client can choose whose name goes on a document.
create or replace function public.sign_invoice(
  p_invoice_id      uuid,
  p_document_sha256 text,
  p_ip              inet default null,
  p_user_agent      text default null
)
returns invoice_signatures
language plpgsql
as $$
declare
  v_uid  uuid := auth.uid();
  v_inv  invoices%rowtype;
  v_role signature_role;
  v_name text;
  v_sig  invoice_signatures%rowtype;
begin
  select * into v_inv from invoices where id = p_invoice_id;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;

  if v_inv.apporteur_id = v_uid then
    v_role := 'apporteur';
  elsif is_admin(v_uid) then
    v_role := 'entreprise';
  else
    raise exception 'you are not a party to this invoice' using errcode = '42501';
  end if;

  -- what is signed must be the document that was shown
  if v_inv.pdf_sha256 is distinct from p_document_sha256 then
    raise exception 'the document being signed does not match the issued invoice'
      using errcode = '22023';
  end if;

  select first_name || ' ' || last_name into v_name from profiles where id = v_uid;

  insert into invoice_signatures (invoice_id, signer_id, signer_role, signer_full_name,
                                  document_sha256, ip_address, user_agent)
  values (p_invoice_id, v_uid, v_role, v_name, p_document_sha256, p_ip, p_user_agent)
  returning * into v_sig;

  return v_sig;
end;
$$;

-- ------------------------------------------------------------------- chat

create or replace function public.start_direct_thread(p_other_profile_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_uid    uuid := auth.uid();
  v_thread uuid;
begin
  -- reuse the existing conversation rather than stacking duplicates
  select t.id into v_thread
    from threads t
    join thread_participants a on a.thread_id = t.id and a.profile_id = v_uid
    join thread_participants b on b.thread_id = t.id and b.profile_id = p_other_profile_id
   where t.kind = 'direct'
   limit 1;

  if v_thread is not null then
    return v_thread;
  end if;

  insert into threads (kind, created_by) values ('direct', v_uid) returning id into v_thread;
  insert into thread_participants (thread_id, profile_id)
  values (v_thread, v_uid), (v_thread, p_other_profile_id);

  return v_thread;
end;
$$;

create or replace function public.open_ticket(
  p_subject  text,
  p_body     text,
  p_priority ticket_priority default 'normal'
)
returns uuid
language plpgsql
as $$
declare
  v_uid    uuid := auth.uid();
  v_thread uuid;
  v_admin  uuid;
begin
  insert into threads (kind, title, created_by)
  values ('ticket', p_subject, v_uid) returning id into v_thread;

  insert into thread_participants (thread_id, profile_id) values (v_thread, v_uid);

  -- put a human on it immediately; assignment can be changed in the console
  v_admin := support_admin_id();
  if v_admin is not null then
    insert into thread_participants (thread_id, profile_id) values (v_thread, v_admin);
  end if;

  insert into messages (thread_id, sender_id, body) values (v_thread, v_uid, p_body);
  insert into tickets (thread_id, opener_id, assignee_id, subject, priority)
  values (v_thread, v_uid, v_admin, p_subject, p_priority);

  return v_thread;
end;
$$;

create or replace function public.mark_thread_read(p_thread_id uuid)
returns void
language sql
as $$
  -- clock_timestamp() to match messages.created_at: now() is the transaction's
  -- start, so a message written earlier in the same transaction would keep
  -- counting as unread after the reader had opened the conversation.
  update thread_participants set last_read_at = clock_timestamp()
   where thread_id = p_thread_id and profile_id = auth.uid();
$$;

-- Powers the unread badges. RLS on messages means this can only ever count
-- conversations the caller belongs to.
create or replace function public.unread_counts()
returns jsonb
language sql
stable
as $$
  select coalesce(jsonb_object_agg(thread_id, n), '{}'::jsonb)
  from (
    select m.thread_id, count(*) as n
      from messages m
      join thread_participants p
        on p.thread_id = m.thread_id and p.profile_id = auth.uid()
     where m.sender_id <> auth.uid()
       and (p.last_read_at is null or m.created_at > p.last_read_at)
     group by m.thread_id
  ) t;
$$;
