-- Energy Courtage — the filleul's rights, closed sign-up, and crash reports.
--
--   * A lost lead kept the prospect's name, phone and email forever, though
--     nobody ever asked them anything. It is now anonymised after a retention
--     period the company sets (36 months by default -- "3 ans après le dernier
--     contact est l'usage", as the draft privacy policy puts it, pending the
--     lawyer). A prospect who asks can be erased, or sent everything held
--     about them, at once. An apporteur can export their own data.
--   * Sign-up was open: anyone could create an account, and the invitation
--     only mattered afterwards. Accounts are now created by inviting an email
--     address (the send-invite function), and redeeming needs no code typed in:
--     the invitation addressed to the account's email is the one used.
--   * Crashes and hangs were invisible. The app now hands iOS's MetricKit
--     reports to the server, where the company can read them.

-- ===================================================== retention period
alter table billing_settings
  add column lead_retention_months int not null default 36
  constraint billing_settings_retention check (lead_retention_months between 6 and 120);

-- ========================================================= anonymising
-- The filleul's personal data on one lead, gone. What a signed invoice says
-- is untouched: it carries its own copy of the filleul's name (the invoice
-- snapshot), which the law requires keeping. Returns the storage paths of the
-- documents removed, for the caller to delete the bytes through the Storage
-- API -- deleting storage rows in SQL would leave the files behind.
create or replace function public.anonymise_filleul(p_recommendation_id uuid, p_reason text)
returns text[]
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_paths text[];
begin
  select coalesce(array_agg(storage_path), '{}') into v_paths
    from documents where recommendation_id = p_recommendation_id;

  delete from documents where recommendation_id = p_recommendation_id;
  delete from personal_notes where recommendation_id = p_recommendation_id;

  update recommendations
     set filleul_first_name = 'Prospect', filleul_last_name = 'anonymisé',
         filleul_phone = null, filleul_email = null, filleul_company = null,
         filleul_siret = null, filleul_address = null
   where id = p_recommendation_id;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (auth.uid(), 'recommendations', p_recommendation_id, 'anonymise_filleul',
          jsonb_build_object('reason', p_reason, 'documents', cardinality(v_paths)));
  return v_paths;
end;
$$;

-- A prospect who asks to be forgotten (RGPD art. 17). Admin only.
create or replace function public.erase_filleul(p_recommendation_id uuid)
returns text[]
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_admin(auth.uid()) then
    raise exception 'only an administrator erases a prospect' using errcode = '42501';
  end if;
  if not exists (select 1 from recommendations where id = p_recommendation_id) then
    raise exception 'recommendation not found' using errcode = 'P0002';
  end if;
  return anonymise_filleul(p_recommendation_id, 'demande de la personne');
end;
$$;

-- The monthly sweep: leads lost, or left untouched, for longer than the
-- retention period. A deal that was won is a client relationship, not a
-- prospect's data, and is not swept.
create or replace function public.purge_stale_leads()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_months int := coalesce((select lead_retention_months from billing_settings), 36);
  v_id     uuid;
  v_paths  text[] := '{}';
  v_n      int := 0;
begin
  for v_id in
    select id from recommendations r
     where r.filleul_last_name is distinct from 'anonymisé'
       and r.reward_status in ('pending', 'cancelled')
       and (
         (r.status = 'archived_lost'
          and coalesce(r.archived_at, r.updated_at) < now() - make_interval(months => v_months))
         or (r.status = 'active'
          and r.updated_at < now() - make_interval(months => v_months))
         or (r.deleted_at is not null
          and r.deleted_at < now() - make_interval(months => v_months))
       )
     limit 500
  loop
    v_paths := v_paths || anonymise_filleul(v_id, 'durée de conservation dépassée');
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('anonymised', v_n, 'retention_months', v_months,
                            'document_paths', to_jsonb(v_paths));
end;
$$;

-- What is held about a prospect, by phone or email, for a right-of-access
-- request (RGPD art. 15). Admin only.
create or replace function public.filleul_data_export(p_phone text default null,
                                                      p_email text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_admin(auth.uid()) then
    raise exception 'only an administrator answers an access request' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'recommendation_id', r.id,
      'recorded_on', r.created_at,
      'consent_confirmed_at', r.consent_confirmed_at,
      'first_name', r.filleul_first_name, 'last_name', r.filleul_last_name,
      'phone', r.filleul_phone, 'email', r.filleul_email,
      'company', r.filleul_company, 'siret', r.filleul_siret, 'address', r.filleul_address,
      'recommended_by', r.parrain_name,
      'stage', (select label from stages where id = r.current_stage_id),
      'status', r.status,
      'documents', (select coalesce(jsonb_agg(jsonb_build_object(
                      'filename', d.filename, 'kind', d.kind, 'added_on', d.created_at)), '[]')
                      from documents d where d.recommendation_id = r.id)
    ) order by r.created_at)
    from recommendations r
    where (normalise_phone(p_phone) is not null and normalise_phone(r.filleul_phone) = normalise_phone(p_phone))
       or (nullif(lower(p_email), '') is not null and lower(r.filleul_email) = lower(p_email))
  ), '[]'::jsonb);
end;
$$;

-- An apporteur's own data, in one file (RGPD art. 15 and 20).
create or replace function public.export_my_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or not exists (select 1 from profiles where id = v_uid) then
    raise exception 'no profile for this account' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(p) - 'bank_details_reference' from profiles p where id = v_uid),
    'recommendations', (select coalesce(jsonb_agg(to_jsonb(r) - 'search_text' order by r.created_at), '[]')
                          from recommendations r where r.parrain_id = v_uid and r.deleted_at is null),
    'invoices', (select coalesce(jsonb_agg(invoice_document(i.id) order by i.sequence_year, i.sequence_index), '[]')
                   from invoices i where i.apporteur_id = v_uid),
    'commissions', (select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at), '[]')
                      from commissions c where c.profile_id = v_uid),
    'legal_acceptances', (select coalesce(jsonb_agg(to_jsonb(a) order by a.accepted_at), '[]')
                            from legal_acceptances a where a.profile_id = v_uid),
    'personal_notes', (select coalesce(jsonb_agg(jsonb_build_object(
                          'recommendation_id', n.recommendation_id, 'body', n.body,
                          'updated_at', n.updated_at)), '[]')
                         from personal_notes n where n.author_id = v_uid),
    'messages_sent', (select coalesce(jsonb_agg(jsonb_build_object(
                         'thread_id', m.thread_id, 'body', m.body, 'sent_at', m.created_at)
                         order by m.created_at), '[]')
                        from messages m where m.sender_id = v_uid)
  );
end;
$$;

-- ============================================== invitations, by address
-- An invitation is redeemed by the account its email was sent to; no code to
-- type. A code still works, for an invitation that was read out instead.
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

  if coalesce(btrim(p_first_name), '') = '' or coalesce(btrim(p_last_name), '') = '' then
    raise exception 'first and last name are required' using errcode = '22023';
  end if;

  select email into v_email from auth.users where id = v_uid;

  if nullif(btrim(coalesce(p_code, '')), '') is null then
    select * into v_invite from invites
     where email = lower(v_email) and used_at is null and expires_at >= now()
     order by created_at desc
     limit 1
     for update;
  else
    select * into v_invite from invites
     where code = upper(btrim(p_code))
     for update;
  end if;

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
          btrim(p_first_name), btrim(p_last_name), v_email)
  returning * into v_profile;

  update invites set used_at = now(), used_by = v_uid where code = v_invite.code;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_uid, 'profiles', v_uid, 'redeem_invite',
          jsonb_build_object('role', v_invite.role));

  return v_profile;
end;
$$;

-- An invitation now always names who it is for: the email is how it arrives.
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
  if coalesce(btrim(p_email), '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'an invitation is sent to an email address' using errcode = '22023';
  end if;
  if exists (select 1 from profiles where lower(email) = lower(btrim(p_email))) then
    raise exception 'this address already has an account' using errcode = '23505';
  end if;

  v_code := translate(upper(substr(encode(gen_random_bytes(8), 'base64'), 1, 10)),
                      '+/=OIL01', 'XYZWMNPQ');

  insert into invites (code, email, role, auto_activate, created_by)
  values (v_code, lower(btrim(p_email)), p_role, p_auto_activate, auth.uid())
  returning * into v_invite;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (auth.uid(), 'invites', null, 'create_invite',
          jsonb_build_object('email', v_invite.email, 'role', p_role));
  return v_invite;
end;
$$;

-- ========================================================= diagnostics
-- MetricKit's crash, hang and launch reports, from the phones. Read by the
-- company; written only through report_diagnostic, which bounds them.
create table client_diagnostics (
  id          bigserial primary key,
  profile_id  uuid references profiles(id) on delete set null,
  kind        text not null,
  app_version text,
  os_version  text,
  payload     jsonb not null,
  created_at  timestamptz not null default now()
);
create index client_diagnostics_recent_idx on client_diagnostics (created_at desc);

alter table client_diagnostics enable row level security;
create policy client_diagnostics_admin_read on client_diagnostics for select to authenticated
  using ((select is_admin((select auth.uid()))));
grant select on client_diagnostics to authenticated;

create or replace function public.report_diagnostic(
  p_kind        text,
  p_app_version text,
  p_os_version  text,
  p_payload     jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_kind not in ('crash', 'hang', 'cpu', 'disk', 'launch', 'error') then
    raise exception 'unknown diagnostic kind' using errcode = '22023';
  end if;
  -- a phone in a crash loop must not fill the table
  if (select count(*) from client_diagnostics
       where profile_id = v_uid and created_at > now() - interval '1 day') >= 30 then
    return;
  end if;
  if octet_length(p_payload::text) > 64 * 1024 then
    p_payload := jsonb_build_object('truncated', true,
                                    'head', left(p_payload::text, 60 * 1024));
  end if;
  insert into client_diagnostics (profile_id, kind, app_version, os_version, payload)
  values (v_uid, p_kind, left(p_app_version, 40), left(p_os_version, 40), p_payload);
end;
$$;

-- ============================================================== grants
revoke execute on function public.anonymise_filleul(uuid, text) from public, anon, authenticated;
revoke execute on function public.purge_stale_leads() from public, anon, authenticated;
grant execute on function public.purge_stale_leads() to service_role;
grant execute on function public.anonymise_filleul(uuid, text) to service_role;

revoke execute on function public.erase_filleul(uuid) from public, anon;
revoke execute on function public.filleul_data_export(text, text) from public, anon;
revoke execute on function public.export_my_data() from public, anon;
revoke execute on function public.report_diagnostic(text, text, text, jsonb) from public, anon;
grant execute on function public.erase_filleul(uuid) to authenticated, service_role;
grant execute on function public.filleul_data_export(text, text) to authenticated, service_role;
grant execute on function public.export_my_data() to authenticated, service_role;
grant execute on function public.report_diagnostic(text, text, text, jsonb) to authenticated, service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- the 1st of each month, 03:00: the gdpr-purge function anonymises and
    -- deletes the documents' bytes through the Storage API
    perform cron.schedule('gdpr-purge', '0 3 1 * *',
      $q$select public.call_edge_hook('gdpr-purge', '{}'::jsonb)$q$);
  end if;
exception when others then
  raise notice 'pg_cron unavailable: the retention purge is not scheduled';
end $$;
