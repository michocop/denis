-- Energy Courtage — push, wired like every other hook, and worth receiving.
--
-- What stood between the push sender and a lock screen:
--   * its address and secret lived in push_config, which nothing filled in.
--     scripts/deploy.sh registers every hook in edge_hooks, so the day the
--     Apple key arrived the trigger would still have found no configuration
--     and sent nothing;
--   * the icon's badge only moved while the app was open: a push arrived and
--     left yesterday's count on the home screen;
--   * three things people wait for were never said at all: that their account
--     is open, that a lead went nowhere, and that the company countersigned
--     their invoice.
--
-- And one thing it should not send. A reminder already rings on the phone
-- that set it, at the minute it was set for (LocalNotifications.schedule);
-- the server's copy, up to five minutes later, is the same reminder twice.
-- It stays in the list and goes by email, as before.

-- ============================================================ the hook
create or replace function public.dispatch_push_notification()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.kind = 'reminder_due' then
    return null;
  end if;

  perform call_edge_hook('send-push', jsonb_build_object('record', jsonb_build_object(
    'id',                new.id,
    'profile_id',        new.profile_id,
    'kind',              new.kind,
    'title',             notification_title(new.kind, new.payload),
    'body',              notification_body(new.kind, new.payload),
    'thread_id',         new.payload ->> 'thread_id',
    'recommendation_id', new.payload ->> 'recommendation_id',
    'invoice_id',        new.payload ->> 'invoice_id',
    -- what unread_notification_count() will say, this row included, so the
    -- icon matches the bell the moment the app opens
    'badge',             (select count(*) from notifications
                           where profile_id = new.profile_id and read_at is null))));
  return null;
exception when others then
  -- a failed push must never roll back what caused it
  return null;
end;
$$;

-- A configuration someone had typed in by hand moves across; otherwise the
-- hook is registered by scripts/deploy.sh once the Apple key is set.
insert into edge_hooks (name, url, secret, enabled)
select 'send-push', function_url, hook_secret, enabled from push_config
on conflict (name) do nothing;

drop table push_config;

-- ======================================================== the apporteur
-- An account an admin has just approved. Whoever signed up has been looking
-- at a waiting screen, or has closed the app and moved on: this is how they
-- learn they can start.
create or replace function public.alert_member_approved()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.status = 'pending' and new.status = 'active' then
    insert into notifications (profile_id, kind, payload)
    values (new.id, 'member_approved', jsonb_build_object('first_name', new.first_name));
  end if;
  return null;
end;
$$;

create trigger profiles_alert_approved after update of status on profiles
  for each row execute function public.alert_member_approved();

-- A lead closed as lost. Without this the apporteur finds out by noticing it
-- moved to Archivées, if they ever do.
create or replace function public.alert_recommendation_lost()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.status = 'active' and new.status = 'archived_lost'
     and new.parrain_id is distinct from auth.uid() then
    insert into notifications (profile_id, kind, payload)
    values (new.parrain_id, 'recommendation_lost',
            jsonb_build_object('recommendation_id', new.id,
                               'filleul', new.filleul_first_name || ' ' || new.filleul_last_name));
  end if;
  return null;
end;
$$;

create trigger recommendations_alert_lost after update of status on recommendations
  for each row execute function public.alert_recommendation_lost();

-- The company's signature is in: the invoice is complete and payment follows.
-- Not when the apporteur's own signature is the one that completed it -- they
-- know, they just did it.
create or replace function public.alert_invoice_countersigned()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'signed' and old.status is distinct from 'signed'
     and new.apporteur_id is distinct from auth.uid() then
    insert into notifications (profile_id, kind, payload)
    values (new.apporteur_id, 'invoice_signed',
            jsonb_build_object('invoice_id', new.id,
                               'number', new.number,
                               'amount', to_char(new.amount_ttc, 'FM999999990.00')));
  end if;
  return null;
end;
$$;

create trigger invoices_alert_countersigned after update of status on invoices
  for each row execute function public.alert_invoice_countersigned();

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
    when 'member_approved'  then 'Compte activé'
    when 'recommendation_lost' then 'Recommandation sans suite'
    when 'invoice_signed'   then 'Facture signée'
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
      || coalesce(' — ' || format_euros(p_payload ->> 'amount'), '')
    when 'message_received' then coalesce(p_payload ->> 'excerpt', '')
    when 'invoice_ready' then
      'Facture ' || coalesce(p_payload ->> 'number', '')
      || coalesce(' — ' || format_euros(p_payload ->> 'amount'), '')
    when 'payment_sent' then
      coalesce(format_euros(p_payload ->> 'amount'), 'Votre paiement') || ' en route'
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
    when 'member_approved' then
      'Votre compte est validé : vous pouvez recommander vos premiers contacts.'
    when 'recommendation_lost' then
      'Le dossier de ' || coalesce(p_payload ->> 'filleul', 'votre filleul')
      || ' est clôturé sans suite.'
    when 'invoice_signed' then
      'Facture ' || coalesce(p_payload ->> 'number', '') || ' signée des deux parties'
      || coalesce(' — ' || format_euros(p_payload ->> 'amount'), '')
    else ''
  end;
$$;

-- ============================================================== email
-- An approval is the one new kind worth an email: the person it is for may
-- not have the app open, or a device registered, yet. A lost lead is not news
-- to send by mail, and the countersigned invoice is already emailed, with its
-- PDF, by invoice-pdf.
create or replace function public.is_email_worthy(p_kind text)
returns boolean
language sql
immutable
as $$
  select p_kind in ('invoice_ready', 'reward_earned', 'payment_sent', 'reminder_due',
                    'lead_created', 'member_pending', 'invoice_signed_by_apporteur',
                    'document_added', 'member_approved');
$$;
