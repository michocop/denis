-- Energy Courtage — reminders that fire, alerts for the company, and email.
--
-- Three things that were written down and never happened:
--   * a reminder had a due date and nothing ever looked at it, so "relancer
--     jeudi" fired only on the phone that created it, if that phone was on;
--   * the company was never told anything: not a new lead, not a member
--     waiting for approval, not an apporteur's signature, not a bill sent in;
--   * nothing was ever emailed, so someone without push enabled -- or away
--     from the app for a week -- missed the invoice they had to sign.

-- ============================================================ reminders
-- Every five minutes: what is due becomes a notification for whoever set it,
-- which then goes out by push and email like any other.
create or replace function public.dispatch_due_reminders()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_n int;
begin
  with due as (
    update reminders set status = 'sent'
     where status = 'scheduled' and due_at <= now()
    returning id, recommendation_id, created_by, label
  )
  insert into notifications (profile_id, kind, payload)
  select d.created_by, 'reminder_due',
         jsonb_build_object('reminder_id', d.id, 'recommendation_id', d.recommendation_id,
                            'label', d.label,
                            'filleul', r.filleul_first_name || ' ' || r.filleul_last_name)
    from due d join recommendations r on r.id = d.recommendation_id;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ============================================================== admins
-- Who at the company hears about something: the admin following that lead if
-- there is one, otherwise every active admin. Never the person who did it.
create or replace function public.notify_admins(
  p_kind              text,
  p_payload           jsonb,
  p_recommendation_id uuid default null,
  p_actor             uuid default auth.uid()
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_assigned uuid;
begin
  if p_recommendation_id is not null then
    select assigned_admin_id into v_assigned from recommendations where id = p_recommendation_id;
    if v_assigned is not null and not is_admin(v_assigned) then
      v_assigned := null;
    end if;
  end if;

  insert into notifications (profile_id, kind, payload)
  select p.id, p_kind, p_payload
    from profiles p
   where p.role in ('admin', 'manager') and p.status = 'active'
     and (v_assigned is null or p.id = v_assigned)
     and p.id is distinct from p_actor;
end;
$$;

create or replace function public.alert_new_lead()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform notify_admins('lead_created',
    jsonb_build_object('recommendation_id', new.id,
                       'filleul', new.filleul_first_name || ' ' || new.filleul_last_name,
                       'parrain', new.parrain_name),
    new.id, new.parrain_id);
  return null;
end;
$$;

create trigger recos_alert_admins after insert on recommendations
  for each row execute function public.alert_new_lead();

create or replace function public.alert_pending_member()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'pending' then
    perform notify_admins('member_pending',
      jsonb_build_object('profile_id', new.id,
                         'name', new.first_name || ' ' || new.last_name),
      null, new.id);
  end if;
  return null;
end;
$$;

create trigger profiles_alert_pending after insert on profiles
  for each row execute function public.alert_pending_member();

-- The apporteur's half is in: the company's signature is what is missing.
create or replace function public.alert_apporteur_signature()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_inv invoices%rowtype;
begin
  if new.signer_role = 'apporteur' then
    select * into v_inv from invoices where id = new.invoice_id;
    perform notify_admins('invoice_signed_by_apporteur',
      jsonb_build_object('invoice_id', v_inv.id, 'recommendation_id', v_inv.recommendation_id,
                         'number', v_inv.number, 'apporteur', new.signer_full_name),
      v_inv.recommendation_id, new.signer_id);
  end if;
  return null;
end;
$$;

create trigger invoice_signatures_alert after insert on invoice_signatures
  for each row execute function public.alert_apporteur_signature();

create or replace function public.alert_document_added()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_admin(new.uploaded_by) then
    perform notify_admins('document_added',
      jsonb_build_object('recommendation_id', new.recommendation_id,
                         'filename', new.filename, 'kind', new.kind,
                         'filleul', (select filleul_first_name || ' ' || filleul_last_name
                                       from recommendations where id = new.recommendation_id)),
      new.recommendation_id, new.uploaded_by);
  end if;
  return null;
end;
$$;

create trigger documents_alert_admins after insert on documents
  for each row execute function public.alert_document_added();

-- ================================================================ text
create or replace function public.notification_title(p_kind text, p_payload jsonb)
returns text
language sql
immutable
as $$
  select case p_kind
    when 'stage_advanced'   then 'Votre recommandation avance'
    when 'reward_earned'    then 'Commission acquise'
    when 'message_received' then coalesce(p_payload ->> 'sender', 'Nouveau message')
    when 'invoice_ready'    then 'Facture à signer'
    when 'payment_sent'     then 'Paiement envoyé'
    when 'reminder_due'     then 'Relance'
    when 'lead_created'     then 'Nouvelle recommandation'
    when 'member_pending'   then 'Inscription à valider'
    when 'invoice_signed_by_apporteur' then 'Facture à contresigner'
    when 'document_added'   then 'Nouveau document'
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
    when 'reminder_due' then
      coalesce(p_payload ->> 'label', 'Relance prévue')
      || coalesce(' — ' || (p_payload ->> 'filleul'), '')
    when 'lead_created' then
      coalesce(p_payload ->> 'filleul', 'Un filleul')
      || coalesce(', recommandé par ' || (p_payload ->> 'parrain'), '')
    when 'member_pending' then
      coalesce(p_payload ->> 'name', 'Un nouveau membre') || ' attend votre validation'
    when 'invoice_signed_by_apporteur' then
      coalesce(p_payload ->> 'apporteur', 'L''apporteur') || ' a signé la facture '
      || coalesce(p_payload ->> 'number', '')
    when 'document_added' then
      coalesce(p_payload ->> 'filename', 'Un document')
      || coalesce(' — ' || (p_payload ->> 'filleul'), '')
    else ''
  end;
$$;

-- ============================================================== email
-- Off per person, on by default. Their own column, so profiles_update lets
-- them change it and guard_profile_columns leaves it alone.
alter table profiles add column email_notifications boolean not null default true;

-- What is worth an email: what someone has to act on, or is owed money for.
-- A chat message is not -- the push and the badge are enough, and mail per
-- message is how people learn to filter a sender.
create or replace function public.is_email_worthy(p_kind text)
returns boolean
language sql
immutable
as $$
  select p_kind in ('invoice_ready', 'reward_earned', 'payment_sent', 'reminder_due',
                    'lead_created', 'member_pending', 'invoice_signed_by_apporteur',
                    'document_added');
$$;

create or replace function public.dispatch_email_notification()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if is_email_worthy(new.kind) then
    perform call_edge_hook('notify-email', jsonb_build_object('notification_id', new.id));
  end if;
  return null;
end;
$$;

create trigger notifications_dispatch_email after insert on notifications
  for each row execute function public.dispatch_email_notification();

-- What the notify-email function sends, and to whom. Null when there is
-- nobody to send to: a deleted account, or someone who turned email off.
create or replace function public.notification_email(p_notification_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'to', p.email,
    'first_name', p.first_name,
    'kind', n.kind,
    'title', notification_title(n.kind, n.payload),
    'body', notification_body(n.kind, n.payload))
  from notifications n
  join profiles p on p.id = n.profile_id
  where n.id = p_notification_id
    and p.status = 'active'
    and p.email_notifications
    and p.email not like 'deleted+%@invalid'
    and is_email_worthy(n.kind);
$$;

-- ============================================================= grants
revoke execute on function public.dispatch_due_reminders() from public, anon, authenticated;
revoke execute on function public.notify_admins(text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.notification_email(uuid) from public, anon, authenticated;
grant execute on function public.dispatch_due_reminders() to service_role;
grant execute on function public.notify_admins(text, jsonb, uuid, uuid) to service_role;
grant execute on function public.notification_email(uuid) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('reminders-dispatch', '*/5 * * * *',
                          'select public.dispatch_due_reminders()');
  end if;
exception when others then
  raise notice 'pg_cron unavailable: reminders are not dispatched on a schedule';
end $$;
