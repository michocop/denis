-- Energy Courtage — closing what an audit found open, and the money flows
-- that broke on the way.
--
-- Several of these could be used by any apporteur with the app, and the first
-- by anyone at all, because sign-up is open. Each one has a test in
-- tests/rls_test.sql (sections 32 to 43) that attempts the thing and asserts
-- it is refused; every one of those tests failed before this file.
--
-- A convention used below: a guard trigger treats two contexts as trusted.
--   * auth.uid() is null: no request at all -- a migration, the seed, a job.
--   * current_user is not authenticated/anon: a SECURITY DEFINER function,
--     which runs as its owner rather than as the caller's role. Those check
--     their own caller before writing, so the guard does not have to.

-- ===================================================== 1. who people are
-- profiles_insert let any signed-in account write its own profile, with any
-- role and any status. With sign-up open, that was anybody becoming an admin
-- without ever seeing an invitation. redeem_invite() is SECURITY DEFINER and
-- is the only thing that should create a profile, so the policy goes.
drop policy if exists profiles_insert on profiles;

-- profiles_update lets a person edit their own row, which is right for their
-- phone or SIRET and wrong for every column that grants something: the role,
-- the membership, the VAT regime (it adds 20 % to what the company pays), and
-- whether the company holds their bank details.
create or replace function public.guard_profile_columns()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if is_admin(auth.uid()) then
    return new;
  end if;

  if new.id                      is distinct from old.id
  or new.role                    is distinct from old.role
  or new.status                  is distinct from old.status
  or new.email                   is distinct from old.email
  or new.vat_liable              is distinct from old.vat_liable
  or new.vat_number              is distinct from old.vat_number
  or new.kyc_state               is distinct from old.kyc_state
  or new.bank_details_on_file    is distinct from old.bank_details_on_file
  or new.bank_details_reference  is distinct from old.bank_details_reference
  or new.bank_details_updated_at is distinct from old.bank_details_updated_at
  or new.created_at              is distinct from old.created_at then
    raise exception 'field reserved to an administrator' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger profiles_guard_columns before update on profiles
  for each row execute function public.guard_profile_columns();

-- ================================================ 2. a lead starts clean
-- guard_recommendation_columns() only ran on UPDATE. On INSERT nothing
-- stopped an apporteur filing a lead already at the last stage, with their
-- own commission on it, marked earned -- which issue_invoice() would then
-- have invoiced.
--
-- Consent defaulted to now(), so it was recorded whether or not anybody had
-- asked the filleul. It now has to be sent, and the time is the server's.
alter table recommendations alter column consent_confirmed_at drop default;

create or replace function public.guard_recommendation_insert()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or current_user not in ('authenticated', 'anon') then
    -- the seed and the benchmark load demo leads that nobody consents to
    new.consent_confirmed_at := coalesce(new.consent_confirmed_at, now());
    return new;
  end if;

  if new.consent_confirmed_at is null then
    raise exception 'the filleul''s consent must be confirmed before their details are recorded'
      using errcode = '23502';
  end if;
  new.consent_confirmed_at := now();

  if is_admin(auth.uid()) then
    return new;
  end if;

  -- parrain_id is left alone on purpose: reco_insert refuses a lead filed in
  -- someone else's name, and silently rewriting it would hide the attempt.
  new.current_stage_id  := (select id from stages order by position limit 1);
  new.reward_amount     := null;
  new.reward_status     := 'pending';
  new.status            := 'active';
  new.assigned_admin_id := null;
  new.archived_at       := null;
  new.deleted_at        := null;
  -- who filed a contested lead first is decided by this column
  new.created_at        := now();
  new.updated_at        := now();
  return new;
end;
$$;

create trigger recos_guard_insert before insert on recommendations
  for each row execute function public.guard_recommendation_insert();

-- The same two columns were writable on an existing row, too.
create or replace function public.guard_recommendation_columns()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or is_admin(auth.uid()) then
    return new;
  end if;

  if new.current_stage_id     is distinct from old.current_stage_id
  or new.reward_amount        is distinct from old.reward_amount
  or new.reward_status        is distinct from old.reward_status
  or new.status               is distinct from old.status
  or new.assigned_admin_id    is distinct from old.assigned_admin_id
  or new.parrain_id           is distinct from old.parrain_id
  or new.archived_at          is distinct from old.archived_at
  or new.deleted_at           is distinct from old.deleted_at
  or new.created_at           is distinct from old.created_at
  or new.consent_confirmed_at is distinct from old.consent_confirmed_at then
    raise exception 'field reserved to an administrator' using errcode = '42501';
  end if;

  return new;
end;
$$;

-- ============================================ 3. the pipeline moves forward
-- advance_stage() accepted any stage on any lead: backwards, or on a lead
-- already archived as won or lost. Going back is what "Remettre à zéro" is
-- for, and it keeps the history; a lead that is closed stays closed.
create or replace function public.advance_stage(
  p_recommendation_id uuid,
  p_stage_key         text,
  p_comment           text default null
)
returns recommendations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor   uuid := auth.uid();
  v_stage   stages%rowtype;
  v_reco    recommendations%rowtype;
  v_parrain profiles%rowtype;
  v_current int;
  v_comment text;
begin
  if not is_admin(v_actor) then
    raise exception 'only an admin may advance a recommendation'
      using errcode = '42501';
  end if;

  select * into v_stage from stages where key = p_stage_key;
  if not found then
    raise exception 'unknown stage %', p_stage_key using errcode = '22023';
  end if;

  select * into v_reco from recommendations
   where id = p_recommendation_id and deleted_at is null
   for update;
  if not found then
    raise exception 'recommendation not found' using errcode = 'P0002';
  end if;

  if v_reco.status <> 'active' then
    raise exception 'this recommendation is closed and cannot be advanced'
      using errcode = '42501';
  end if;

  select position into v_current from stages where id = v_reco.current_stage_id;
  if v_stage.position < v_current then
    raise exception 'the pipeline does not go backwards: reset it instead'
      using errcode = '22023';
  end if;

  select * into v_parrain from profiles where id = v_reco.parrain_id;

  v_comment := coalesce(
    p_comment,
    render_template(
      v_stage.comment_template,
      jsonb_build_object(
        'filleul', v_reco.filleul_first_name || ' ' || v_reco.filleul_last_name,
        'parrain', v_parrain.first_name,
        'montant', coalesce(to_char(v_reco.reward_amount, 'FM999G999D00'), '')
      )
    )
  );

  insert into recommendation_stage_events
    (recommendation_id, stage_id, comment, completed_by)
  values
    (p_recommendation_id, v_stage.id, nullif(v_comment, ''), v_actor)
  on conflict do nothing;

  update recommendations
     set current_stage_id = v_stage.id,
         reward_status = case
           when v_stage.is_reward_trigger and reward_status = 'pending' then 'earned'::reward_status
           else reward_status
         end
   where id = p_recommendation_id
  returning * into v_reco;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_actor, 'recommendations', p_recommendation_id, 'advance_stage',
          jsonb_build_object('stage', p_stage_key));

  return v_reco;
end;
$$;

-- A lead lost before the reward stage has its commission cancelled, and was
-- still counted as a conversion because the test was "not pending".
create or replace function public.dashboard_stats()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'active_count',   count(*) filter (where status = 'active'),
    'archived_count', count(*) filter (where status <> 'active'),
    'pending_total',  coalesce(sum(reward_amount) filter (where reward_status = 'pending'), 0),
    'earned_total',   coalesce(sum(reward_amount) filter (where reward_status in ('earned','invoiced')), 0),
    'paid_total',     coalesce(sum(reward_amount) filter (where reward_status = 'paid'), 0),
    'conversion_rate',
      case when count(*) = 0 then 0
           else round(100.0 * count(*) filter (where reward_status in ('earned','invoiced','paid'))
                      / count(*), 1)
      end
  )
  from recommendations
  where deleted_at is null;
$$;

-- ================================================ 4. conversations
-- start_direct_thread() took any profile id, so an apporteur could open a
-- conversation with another apporteur -- and chat_display_name() then handed
-- over that person's name, because they shared a thread. Apporteurs write to
-- the company. Writing the thread rows by hand is closed the same way, in the
-- policy, because start_direct_thread() runs with the caller's rights.
drop policy if exists participants_insert on thread_participants;
create policy participants_insert on thread_participants for insert to authenticated
  with check (
    (select is_admin((select auth.uid())))
    or (
      exists (select 1 from threads t
               where t.id = thread_id and t.created_by = (select auth.uid()))
      and (profile_id = (select auth.uid()) or is_admin(profile_id))
    )
  );

create or replace function public.start_direct_thread(p_other_profile_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_uid    uuid := auth.uid();
  v_thread uuid;
begin
  if v_uid is null or not is_active_member(v_uid) then
    raise exception 'only an active member can start a conversation' using errcode = '42501';
  end if;
  if p_other_profile_id is null or p_other_profile_id = v_uid then
    raise exception 'a conversation needs somebody else in it' using errcode = '22023';
  end if;
  if not is_active_member(p_other_profile_id) then
    raise exception 'no such member' using errcode = 'P0002';
  end if;
  if not is_admin(v_uid) and not is_admin(p_other_profile_id) then
    raise exception 'an apporteur writes to the company, not to another apporteur'
      using errcode = '42501';
  end if;

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

-- ======================================= 5. the duplicate check, throttled
-- Any account, even one with no profile, could ask whether a phone number or
-- an email belonged to a lead, as often as it liked: a lookup service over
-- every prospect in the system. The answer cannot be hidden without losing
-- the warning, which is the point of the feature, so what is limited is who
-- may ask and how often. An honest form checks a handful of numbers.
create table duplicate_checks (
  profile_id uuid not null references profiles(id) on delete cascade,
  checked_at timestamptz not null default clock_timestamp()
);
create index duplicate_checks_recent_idx on duplicate_checks (profile_id, checked_at desc);

-- written only by check_duplicate_filleul(), read by nobody
alter table duplicate_checks enable row level security;
revoke all on duplicate_checks from authenticated, anon;

create or replace function public.check_duplicate_filleul(
  p_phone text default null,
  p_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  v_mine  int;
  v_other int;
begin
  if v_uid is null or not is_active_member(v_uid) then
    raise exception 'only an active member can check a lead' using errcode = '42501';
  end if;

  if (select count(*) from duplicate_checks
       where profile_id = v_uid and checked_at > now() - interval '1 hour') >= 120 then
    raise exception 'too many checks in the last hour: try again later'
      using errcode = '42501';
  end if;
  delete from duplicate_checks where profile_id = v_uid and checked_at < now() - interval '1 day';
  insert into duplicate_checks (profile_id) values (v_uid);

  select
    count(*) filter (where parrain_id = v_uid),
    count(*) filter (where parrain_id <> v_uid)
  into v_mine, v_other
  from recommendations
  where deleted_at is null
    and status = 'active'
    and (
      (normalise_phone(p_phone) is not null
       and normalise_phone(filleul_phone) = normalise_phone(p_phone))
      or (nullif(lower(p_email), '') is not null
          and lower(filleul_email) = lower(p_email))
    );

  return jsonb_build_object(
    'already_yours', v_mine > 0,
    'held_by_someone_else', v_other > 0
  );
end;
$$;

-- ======================================== 6. what an invoice records
-- An invoice read the parties' names, company and SIRET from their live
-- profiles, so editing a profile rewrote every invoice already issued -- while
-- its digest, and the signatures on it, stayed the same. It also made it
-- impossible to erase a person who asked to be deleted without erasing the
-- invoices the law says must be kept. So each invoice keeps both parties, and
-- the filleul's name, as they were when it was issued.
alter table invoices
  add column apporteur_snapshot jsonb,
  add column issuer_snapshot    jsonb,
  add column filleul_name       text;

-- A trigger, not a callable function: a function returning anybody's billing
-- identity by id would be a way to read every profile.
create or replace function public.snapshot_invoice_parties()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  select jsonb_build_object(
           'first_name', first_name, 'last_name', last_name,
           'company_name', company_name, 'siret', siret, 'legal_form', legal_form,
           'address', address, 'postal_code', postal_code, 'city', city,
           'vat_number', vat_number)
    into new.apporteur_snapshot
    from profiles where id = new.apporteur_id;

  select jsonb_build_object(
           'first_name', first_name, 'last_name', last_name,
           'company_name', company_name, 'siret', siret, 'legal_form', legal_form,
           'address', address, 'postal_code', postal_code, 'city', city,
           'vat_number', vat_number)
    into new.issuer_snapshot
    from profiles where id = new.issuer_id;

  select filleul_first_name || ' ' || filleul_last_name
    into new.filleul_name
    from recommendations where id = new.recommendation_id;
  return new;
end;
$$;

create trigger invoices_snapshot_parties before insert on invoices
  for each row execute function public.snapshot_invoice_parties();

-- Existing invoices are sealed against every change, which is what this needs
-- to get past once: it records what they already say, it does not alter it.
alter table invoices disable trigger invoices_immutable;
alter table invoices disable trigger invoices_touch;
update invoices i
   set apporteur_snapshot = jsonb_build_object(
         'first_name', a.first_name, 'last_name', a.last_name,
         'company_name', a.company_name, 'siret', a.siret, 'legal_form', a.legal_form,
         'address', a.address, 'postal_code', a.postal_code, 'city', a.city,
         'vat_number', a.vat_number),
       issuer_snapshot = jsonb_build_object(
         'first_name', s.first_name, 'last_name', s.last_name,
         'company_name', s.company_name, 'siret', s.siret, 'legal_form', s.legal_form,
         'address', s.address, 'postal_code', s.postal_code, 'city', s.city,
         'vat_number', s.vat_number),
       filleul_name = r.filleul_first_name || ' ' || r.filleul_last_name
  from profiles a, profiles s, recommendations r
 where a.id = i.apporteur_id and s.id = i.issuer_id and r.id = i.recommendation_id;
alter table invoices enable trigger invoices_immutable;
alter table invoices enable trigger invoices_touch;

alter table invoices
  alter column apporteur_snapshot set not null,
  alter column issuer_snapshot    set not null,
  alter column filleul_name       set not null;

-- Same text, same order, same digest as before for an invoice whose parties
-- have not changed; the difference is only where the values come from.
create or replace function public.invoice_canonical_text(p_invoice_id uuid)
returns text
language sql
stable
as $$
  select concat_ws(E'\n',
    i.number,
    (i.issuer_snapshot ->> 'first_name') || ' ' || (i.issuer_snapshot ->> 'last_name'),
    coalesce(i.issuer_snapshot ->> 'company_name', ''),
    coalesce(i.issuer_snapshot ->> 'city', ''),
    (i.apporteur_snapshot ->> 'first_name') || ' ' || (i.apporteur_snapshot ->> 'last_name'),
    coalesce(i.apporteur_snapshot ->> 'siret', ''),
    i.filleul_name,
    i.prestation_label,
    to_char(i.intervened_on, 'YYYY-MM-DD'),
    to_char(i.amount_ht, 'FM999999990.00'),
    to_char(i.vat_rate,  'FM990.00'),
    to_char(i.vat_amount, 'FM999999990.00'),
    to_char(i.amount_ttc, 'FM999999990.00'),
    i.currency,
    i.legal_mentions,
    i.payment_method,
    i.place,
    to_char(i.issued_on, 'YYYY-MM-DD'),
    coalesce(i.tax_notice, '')
  )
  from invoices i
  where i.id = p_invoice_id;
$$;

create or replace function public.invoice_document(p_invoice_id uuid)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'number', i.number,
    'document_sha256', i.document_sha256,
    'pdf_path', i.pdf_path,
    'corrects_invoice_id', i.corrects_invoice_id,
    'issuer', jsonb_build_object(
      'name',        (i.issuer_snapshot ->> 'first_name') || ' ' || (i.issuer_snapshot ->> 'last_name'),
      'company',     i.issuer_snapshot ->> 'company_name',
      'city',        i.issuer_snapshot ->> 'city',
      'siret',       i.issuer_snapshot ->> 'siret',
      'address',     i.issuer_snapshot ->> 'address',
      'postal_code', i.issuer_snapshot ->> 'postal_code',
      'vat_number',  i.issuer_snapshot ->> 'vat_number'
    ),
    'apporteur', jsonb_build_object(
      'name',        (i.apporteur_snapshot ->> 'first_name') || ' ' || (i.apporteur_snapshot ->> 'last_name'),
      'company',     i.apporteur_snapshot ->> 'company_name',
      'siret',       i.apporteur_snapshot ->> 'siret',
      'legal_form',  i.apporteur_snapshot ->> 'legal_form',
      'address',     i.apporteur_snapshot ->> 'address',
      'postal_code', i.apporteur_snapshot ->> 'postal_code',
      'city',        i.apporteur_snapshot ->> 'city',
      'vat_number',  i.apporteur_snapshot ->> 'vat_number'
    ),
    'attestation', jsonb_build_object(
      'soussigne',       (i.apporteur_snapshot ->> 'first_name') || ' ' || (i.apporteur_snapshot ->> 'last_name'),
      'mis_en_relation', i.issuer_snapshot ->> 'company_name',
      'avec',            i.filleul_name,
      'prestation',      i.prestation_label,
      'intervenue_le',   to_char(i.intervened_on, 'DD.MM.YYYY')
    ),
    'amount', jsonb_build_object(
      'ht',       to_char(i.amount_ht, 'FM999999990.00'),
      'vat_rate', i.vat_rate,
      'vat',      to_char(i.vat_amount, 'FM999999990.00'),
      'ttc',      to_char(i.amount_ttc, 'FM999999990.00'),
      'currency', i.currency
    ),
    'legal_mentions', i.legal_mentions,
    'payment_method', i.payment_method,
    'place',          i.place,
    'issued_on',      to_char(i.issued_on, 'DD.MM.YYYY'),
    'tax_notice',     i.tax_notice,
    'status',         i.status,
    'signatures', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'role',      expected.role,
               'name',      coalesce(s.signer_full_name,
                              case expected.role
                                when 'apporteur' then
                                  (i.apporteur_snapshot ->> 'first_name') || ' ' || (i.apporteur_snapshot ->> 'last_name')
                                else
                                  (i.issuer_snapshot ->> 'first_name') || ' ' || (i.issuer_snapshot ->> 'last_name')
                              end),
               'signed',    s.id is not null,
               'signed_at', s.signed_at
             ) order by expected.ord), '[]'::jsonb)
      from (values ('apporteur'::signature_role, 1), ('entreprise'::signature_role, 2))
           as expected(role, ord)
      left join invoice_signatures s
             on s.invoice_id = i.id and s.signer_role = expected.role
    )
  )
  from invoices i
  where i.id = p_invoice_id;
$$;

-- ============================================ 7. an issued invoice is fixed
-- Only a SEALED invoice was frozen. Before both signatures, an admin could
-- change the amount after the apporteur had signed the old one -- the
-- signature bound to a digest the invoice no longer matched. An admin could
-- also set a draft straight to 'signed' or 'paid' with nobody's agreement, or
-- switch a signed invoice to 'void', which cancels it without the credit note
-- the series requires.
--
-- Now the contents are fixed from the moment of issue. To correct an unsigned
-- invoice, void it and issue another; a signed one takes a credit note.
create or replace function public.guard_invoice_immutability()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- the digest is written once, by stamp_invoice_digest(), just after insert
  if old.document_sha256 is not null
     and new.document_sha256 is distinct from old.document_sha256 then
    raise exception 'invoice % has been issued and cannot be modified', old.number
      using errcode = '42501';
  end if;

  -- the retained file is written once, after sealing
  if (old.pdf_path is not null and new.pdf_path is distinct from old.pdf_path)
     or (old.pdf_sha256 is not null and new.pdf_sha256 is distinct from old.pdf_sha256) then
    raise exception 'invoice % already has a retained document', old.number
      using errcode = '42501';
  end if;

  if to_jsonb(new) - 'status' - 'updated_at' - 'pdf_path' - 'pdf_sha256' - 'document_sha256'
     is distinct from
     to_jsonb(old) - 'status' - 'updated_at' - 'pdf_path' - 'pdf_sha256' - 'document_sha256' then
    raise exception
      'invoice % has been issued and cannot be modified: void it, or credit it once signed',
      old.number using errcode = '42501';
  end if;

  if new.status is distinct from old.status then
    if old.status in ('signed', 'paid', 'void')
       and not (old.status = 'signed' and new.status = 'paid') then
      raise exception 'invoice % is sealed: illegal status transition % -> %',
        old.number, old.status, new.status using errcode = '42501';
    end if;

    if new.status = 'signed'
       and (select count(distinct signer_role) from invoice_signatures
             where invoice_id = new.id) < 2 then
      raise exception 'invoice % has not been signed by both parties', old.number
        using errcode = '42501';
    end if;

    if new.status = 'paid' and old.status <> 'signed' then
      raise exception 'invoice % cannot be paid before it is signed', old.number
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- Voiding an unsigned invoice gives the commission back to be invoiced again;
-- otherwise it stayed 'invoiced' against a document that no longer counts,
-- and issue_invoice() would refuse to replace it.
create or replace function public.release_commission_on_void()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'void' and old.status is distinct from 'void'
     and new.corrects_invoice_id is null then
    update recommendations set reward_status = 'earned', updated_at = now()
     where id = new.recommendation_id and reward_status = 'invoiced';
  end if;
  return null;
end;
$$;

create trigger invoices_void_releases after update of status on invoices
  for each row execute function public.release_commission_on_void();

-- ================================================== 8. who can sign what
-- sign_invoice() checked the digest but not the status, and the table itself
-- accepted any digest and any typed name: a void invoice, a paid one, or one
-- already signed could all collect signatures. The rules now sit on the
-- table, so they hold however the row arrives.
create or replace function public.guard_invoice_signature()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_inv invoices%rowtype;
begin
  -- The lock serialises two parties signing at the same moment, so the second
  -- sees the first. Without it each could count one signature, and the
  -- invoice would never seal.
  select * into v_inv from invoices where id = new.invoice_id for update;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;

  -- Checked before anything about the invoice is said, so a stranger learns
  -- nothing from the error. signature_insert enforces the same afterwards.
  if auth.uid() is not null
     and (new.signer_id is distinct from auth.uid()
          or not (v_inv.apporteur_id = new.signer_id or is_admin(new.signer_id))) then
    raise exception 'you are not a party to this invoice' using errcode = '42501';
  end if;

  if v_inv.status not in ('draft', 'awaiting_signatures') then
    raise exception 'invoice % cannot be signed: it is %', v_inv.number, v_inv.status
      using errcode = '42501';
  end if;

  if new.document_sha256 is distinct from v_inv.document_sha256 then
    raise exception 'the document being signed does not match the issued invoice'
      using errcode = '22023';
  end if;

  select first_name || ' ' || last_name into new.signer_full_name
    from profiles where id = new.signer_id;
  new.signed_at := now();
  return new;
end;
$$;

create trigger invoice_signatures_guard before insert on invoice_signatures
  for each row execute function public.guard_invoice_signature();

-- A credit note is signed like any invoice, but sealing it must not mark the
-- commission invoiced: it cancels an invoice, and the commission is owed again.
create or replace function public.seal_invoice_when_fully_signed()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (select count(distinct signer_role) from invoice_signatures
       where invoice_id = new.invoice_id) = 2 then
    update invoices set status = 'signed'
     where id = new.invoice_id and status <> 'signed';

    update recommendations r
       set reward_status = 'invoiced'
      from invoices i
     where i.id = new.invoice_id
       and i.corrects_invoice_id is null
       and r.id = i.recommendation_id
       and r.reward_status = 'earned';
  end if;
  return new;
end;
$$;

-- ======================================= 9. correcting, then reissuing
-- After a credit note the commission went back to 'earned', and then nothing
-- could invoice it: issue_invoice() and set_reward_amount() both treated the
-- credited original, and the credit note itself, as a live invoice. A live
-- invoice is now one that is neither void, nor a credit note, nor credited.
-- Invoker rights: its callers are SECURITY DEFINER already, and a member
-- calling it directly sees only what RLS shows them.
create or replace function public.has_live_invoice(p_recommendation_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from invoices i
     where i.recommendation_id = p_recommendation_id
       and i.status <> 'void'
       and i.corrects_invoice_id is null
       and not exists (select 1 from invoices c where c.corrects_invoice_id = i.id)
  );
$$;

-- A credit note recomputed its VAT from the apporteur's CURRENT status, so an
-- apporteur who had since become VAT-liable got a credit note that did not
-- cancel the original. It copies the original's terms instead.
create or replace function public.compute_invoice_billing()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_liable boolean;
  v_orig   invoices%rowtype;
begin
  if new.corrects_invoice_id is not null then
    select * into v_orig from invoices where id = new.corrects_invoice_id;
    new.vat_mode       := v_orig.vat_mode;
    new.vat_rate       := v_orig.vat_rate;
    new.legal_mentions := v_orig.legal_mentions;
    new.tax_notice     := v_orig.tax_notice;
  else
    select vat_liable into v_liable from profiles where id = new.apporteur_id;

    if coalesce(v_liable, false) then
      new.vat_mode       := 'standard';
      new.vat_rate       := 20.00;
      new.legal_mentions := (select value from invoice_texts where key = 'vat_standard');
    else
      new.vat_mode       := 'franchise_293b';
      new.vat_rate       := 0;
      new.legal_mentions := (select value from invoice_texts where key = 'vat_exempt_293b');
    end if;
    new.tax_notice := coalesce(new.tax_notice,
                               (select value from invoice_texts where key = 'tax_notice'));
  end if;

  new.vat_amount := round(new.amount_ht * new.vat_rate / 100, 2);
  new.amount_ttc := new.amount_ht + new.vat_amount;
  return new;
end;
$$;

create or replace function public.issue_invoice(
  p_recommendation_id uuid,
  p_prestation_label  text default 'Apport d''affaires - mise en relation'
)
returns invoices
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_reco   recommendations%rowtype;
  v_issuer profiles%rowtype;
  v_inv    invoices%rowtype;
begin
  if not is_admin(v_uid) then
    raise exception 'only an administrator issues an invoice' using errcode = '42501';
  end if;

  select * into v_reco from recommendations
   where id = p_recommendation_id and deleted_at is null
   for update;
  if not found then
    raise exception 'recommendation not found' using errcode = 'P0002';
  end if;

  if v_reco.reward_status = 'pending' then
    raise exception 'this recommendation has not reached the reward stage yet'
      using errcode = '42501';
  end if;
  -- 'cancelled' used to get through, so a lost deal could still be invoiced
  if v_reco.reward_status <> 'earned' then
    raise exception 'there is no commission to invoice: it is %', v_reco.reward_status
      using errcode = '42501';
  end if;

  if v_reco.reward_amount is null or v_reco.reward_amount <= 0 then
    raise exception 'set the commission on the recommendation before invoicing it'
      using errcode = '42501';
  end if;

  if has_live_invoice(p_recommendation_id) then
    raise exception 'this recommendation already has an invoice'
      using errcode = '23505';
  end if;

  select * into v_issuer from profiles where id = v_uid;

  insert into invoices (recommendation_id, apporteur_id, issuer_id,
                        prestation_label, intervened_on, place, amount_ht)
  values (p_recommendation_id, v_reco.parrain_id, v_uid,
          p_prestation_label,
          coalesce((select max(completed_at)::date
                      from recommendation_stage_events
                     where recommendation_id = p_recommendation_id
                       and reverted_at is null), current_date),
          coalesce(v_issuer.city, ''),
          v_reco.reward_amount)
  returning * into v_inv;

  update recommendations set reward_status = 'invoiced', updated_at = now()
   where id = p_recommendation_id and reward_status = 'earned';

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_uid, 'invoices', v_inv.id, 'issue_invoice',
          jsonb_build_object('recommendation_id', p_recommendation_id,
                             'amount_ht', v_inv.amount_ht));

  select * into v_inv from invoices where id = v_inv.id;
  return v_inv;
end;
$$;

create or replace function public.set_reward_amount(
  p_recommendation_id uuid,
  p_amount            numeric
)
returns recommendations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := auth.uid();
  v_reco recommendations%rowtype;
begin
  if not is_admin(v_uid) then
    raise exception 'only an administrator sets the commission' using errcode = '42501';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'the commission must be a positive amount' using errcode = '22023';
  end if;

  select * into v_reco from recommendations
   where id = p_recommendation_id and deleted_at is null;
  if not found then
    raise exception 'recommendation not found' using errcode = 'P0002';
  end if;

  if has_live_invoice(p_recommendation_id) then
    raise exception
      'this recommendation is already invoiced: correct it with an avoir instead'
      using errcode = '42501';
  end if;

  update recommendations
     set reward_amount = p_amount, updated_at = now()
   where id = p_recommendation_id
  returning * into v_reco;

  insert into audit_log (actor_id, entity, entity_id, action, before, after)
  values (v_uid, 'recommendations', p_recommendation_id, 'set_reward_amount',
          jsonb_build_object('amount', v_reco.reward_amount),
          jsonb_build_object('amount', p_amount));

  return v_reco;
end;
$$;

-- The statement joined every invoice of a recommendation, so a credit note --
-- and then the corrected invoice -- each added another copy of the same
-- commission. One row per commission, with the invoice that currently stands.
create or replace view commission_statement with (security_invoker = true) as
select
  r.parrain_id,
  extract(year from coalesce(i.issued_on, r.created_at))::int as year,
  r.id as recommendation_id,
  r.filleul_first_name || ' ' || r.filleul_last_name as filleul,
  r.reward_amount,
  r.reward_status,
  i.number  as invoice_number,
  i.issued_on,
  i.amount_ht,
  i.amount_ttc,
  i.status  as invoice_status
from recommendations r
left join lateral (
  select * from invoices x
   where x.recommendation_id = r.id
     and x.status <> 'void'
     and x.corrects_invoice_id is null
     and not exists (select 1 from invoices c where c.corrects_invoice_id = x.id)
   order by x.sequence_year desc, x.sequence_index desc
   limit 1
) i on true
where r.deleted_at is null
  and r.reward_status in ('earned', 'invoiced', 'paid');

-- The card opened the most recent document, which after a correction is the
-- credit note. It opens the invoice that stands, and falls back to the latest
-- document only when there is none. "Latest" is the number in the series, not
-- created_at, which ties for everything written in one transaction.
create or replace view recommendation_feed with (security_invoker = true) as
select
  r.id,
  r.filleul_first_name,
  r.filleul_last_name,
  r.filleul_phone,
  r.filleul_email,
  p.first_name || ' ' || p.last_name as parrain_name,
  r.parrain_id,
  r.assigned_admin_id,
  r.created_at,
  s.key   as current_stage_key,
  s.label as current_stage_label,
  r.reward_amount,
  r.reward_status,
  r.status,
  case when r.reward_status = 'pending' then null else r.reward_amount end
    as displayed_amount,
  greatest(0, extract(day from now() - greatest(
    r.created_at,
    coalesce((select max(completed_at) from recommendation_stage_events e
               where e.recommendation_id = r.id and e.reverted_at is null), r.created_at)
  ))::int) as days_since_activity,
  (
    select coalesce(jsonb_agg(jsonb_build_object(
             'stage_key',    st.key,
             'stage_label',  st.label,
             'position',     st.position,
             'comment',      e.comment,
             'completed_at', e.completed_at
           ) order by st.position), '[]'::jsonb)
    from recommendation_stage_events e
    join stages st on st.id = e.stage_id
    where e.recommendation_id = r.id and e.reverted_at is null
  ) as events,
  exists (
    select 1 from documents d
     where d.recommendation_id = r.id and d.kind in ('contract', 'invoice')
  ) as has_contract,
  (
    select i.number from invoices i
     where i.recommendation_id = r.id
     order by (i.corrects_invoice_id is null and i.status <> 'void'
               and not exists (select 1 from invoices c where c.corrects_invoice_id = i.id)) desc,
              i.sequence_year desc, i.sequence_index desc
     limit 1
  ) as invoice_number,
  (
    select i.id from invoices i
     where i.recommendation_id = r.id
     order by (i.corrects_invoice_id is null and i.status <> 'void'
               and not exists (select 1 from invoices c where c.corrects_invoice_id = i.id)) desc,
              i.sequence_year desc, i.sequence_index desc
     limit 1
  ) as invoice_id,
  exists (
    select 1 from personal_notes n
     where n.recommendation_id = r.id and n.author_id = auth.uid()
  ) as has_note,
  (
    select count(*) from reminders rm
     where rm.recommendation_id = r.id and rm.status = 'scheduled'
  ) as pending_reminders
from recommendations r
join profiles p on p.id = r.parrain_id
join stages   s on s.id = r.current_stage_id
where r.deleted_at is null;

-- ============================================== 10. paying exactly once
-- create_payout_batch() took no locks, so two admins paying at once could
-- both read an invoice as signed and pay it twice. It paid credited invoices
-- (only the payables view hid them, not the function), and paid people whose
-- bank details the company did not hold.
--
-- A credit note on an invoice that was already paid is money owed back, so it
-- appears on the payables list and is settled against the next payment. It
-- cannot be settled alone: a negative transfer is not a payment.
create or replace view payable_invoices with (security_invoker = true) as
select
  i.id                as invoice_id,
  i.number,
  i.issued_on,
  i.amount_ttc,
  i.apporteur_id,
  p.first_name || ' ' || p.last_name as apporteur_name,
  p.bank_details_on_file             as has_bank_details,
  r.id                as recommendation_id,
  r.filleul_first_name || ' ' || r.filleul_last_name as filleul
from invoices i
join profiles p on p.id = i.apporteur_id
join recommendations r on r.id = i.recommendation_id
where i.status = 'signed'
  and not exists (select 1 from invoices c where c.corrects_invoice_id = i.id)
  and (i.corrects_invoice_id is null
       or exists (select 1 from invoices o
                   where o.id = i.corrects_invoice_id and o.status = 'paid'));

create or replace function public.create_payout_batch(
  p_invoice_ids uuid[],
  p_reference   text default null
)
returns payout_batches
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_ids   uuid[];
  v_batch payout_batches%rowtype;
  v_total numeric(12,2);
  v_bad   text;
begin
  if not is_admin(v_actor) then
    raise exception 'only an admin may pay' using errcode = '42501';
  end if;

  v_ids := array(select distinct unnest(p_invoice_ids));
  if coalesce(cardinality(v_ids), 0) = 0 then
    raise exception 'nothing to pay' using errcode = '22023';
  end if;

  -- Lock first. Two batches racing for the same invoice are then taken one
  -- after the other, and the second finds it already paid.
  perform 1 from invoices where id = any(v_ids) order by id for update;

  if (select count(*) from invoices where id = any(v_ids)) <> cardinality(v_ids) then
    raise exception 'batch contains an unknown invoice' using errcode = 'P0002';
  end if;

  select string_agg(number, ', ') into v_bad
    from invoices where id = any(v_ids) and status <> 'signed';
  if v_bad is not null then
    raise exception 'batch contains invoices that are not signed, or already paid: %', v_bad
      using errcode = '22023';
  end if;

  select string_agg(i.number, ', ') into v_bad
    from invoices i
   where i.id = any(v_ids)
     and exists (select 1 from invoices c where c.corrects_invoice_id = i.id);
  if v_bad is not null then
    raise exception 'these invoices have been credited and are not owed: %', v_bad
      using errcode = '22023';
  end if;

  select string_agg(c.number, ', ') into v_bad
    from invoices c join invoices o on o.id = c.corrects_invoice_id
   where c.id = any(v_ids) and o.status <> 'paid';
  if v_bad is not null then
    raise exception 'these credit notes cancel invoices that were never paid: %', v_bad
      using errcode = '22023';
  end if;

  select string_agg(p.first_name || ' ' || p.last_name, ', ') into v_bad
    from profiles p
   where p.id in (select apporteur_id from invoices where id = any(v_ids))
     and not p.bank_details_on_file;
  if v_bad is not null then
    raise exception 'no payment details on file for %', v_bad using errcode = '22023';
  end if;

  select string_agg(p.first_name || ' ' || p.last_name, ', ') into v_bad
    from (select apporteur_id from invoices where id = any(v_ids)
           group by apporteur_id having sum(amount_ttc) <= 0) owed
    join profiles p on p.id = owed.apporteur_id;
  if v_bad is not null then
    raise exception 'nothing is owed to %: a credit note is settled against an invoice', v_bad
      using errcode = '22023';
  end if;

  select sum(amount_ttc) into v_total from invoices where id = any(v_ids);

  insert into payout_batches (period, total, executed_at, executed_by, reference)
  values (to_char(now(), 'YYYY-MM'), v_total, now(), v_actor, p_reference)
  returning * into v_batch;

  insert into commissions (recommendation_id, profile_id, amount, status,
                           earned_at, paid_at, payout_batch_id, invoice_id)
  select i.recommendation_id, i.apporteur_id, i.amount_ttc, 'paid',
         i.issued_on, now(), v_batch.id, i.id
  from invoices i where i.id = any(v_ids);

  update invoices set status = 'paid' where id = any(v_ids);

  -- a credit note settles money; it does not make a commission paid
  update recommendations r
     set reward_status = 'paid'
    from invoices i
   where i.id = any(v_ids) and i.corrects_invoice_id is null
     and r.id = i.recommendation_id;

  -- One notification per person, for what they actually receive. The kind was
  -- 'payout_sent' while the text and the app both knew it as 'payment_sent',
  -- so every one of these showed up as a blank "Notification".
  insert into notifications (profile_id, kind, payload)
  select i.apporteur_id, 'payment_sent',
         jsonb_build_object('batch_id', v_batch.id,
                            'amount', to_char(sum(i.amount_ttc), 'FM999999990.00'),
                            'currency', 'EUR',
                            'invoice_count', count(*))
  from invoices i where i.id = any(v_ids)
  group by i.apporteur_id;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_actor, 'payout_batches', v_batch.id, 'create_payout_batch',
          jsonb_build_object('total', v_total, 'invoices', cardinality(v_ids)));

  return v_batch;
end;
$$;

update notifications set kind = 'payment_sent' where kind = 'payout_sent';

-- ===================================== 11. who keeps the ten-year copy
-- Either party could upload the retained PDF, first writer wins, and the
-- server checks neither the bytes nor the digest it is handed. So the
-- apporteur could make a doctored file the legal copy. Until the PDF is
-- rendered on the server, only the company -- the issuer, who has the
-- retention duty -- stores it. The apporteur still reads it.
drop policy if exists invoice_pdf_write on storage.objects;
create policy invoice_pdf_write on storage.objects for insert to authenticated
  with check (
    bucket_id = 'invoices'
    and (select is_admin((select auth.uid())))
    and exists (
      select 1 from invoices i
       where i.id = invoice_id_from_object_name(storage.objects.name)
         and i.status in ('signed', 'paid')
    )
  );

create or replace function public.record_invoice_pdf(
  p_invoice_id uuid,
  p_path       text,
  p_sha256     text
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_inv invoices%rowtype;
begin
  if not is_admin(auth.uid()) then
    raise exception 'the retained document is kept by the company' using errcode = '42501';
  end if;

  select * into v_inv from invoices where id = p_invoice_id for update;
  if not found then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;

  if v_inv.status not in ('signed', 'paid') then
    raise exception 'invoice % is not signed yet', v_inv.number using errcode = '42501';
  end if;

  if v_inv.pdf_path is not null then
    return v_inv.pdf_path;
  end if;

  if p_path is distinct from p_invoice_id::text || '.pdf'
     or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'a retained document is stored as <invoice id>.pdf with its sha256'
      using errcode = '22023';
  end if;

  update invoices set pdf_path = p_path, pdf_sha256 = p_sha256, updated_at = now()
   where id = p_invoice_id;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (auth.uid(), 'invoices', p_invoice_id, 'pdf_retained',
          jsonb_build_object('path', p_path, 'sha256', p_sha256));

  return p_path;
end;
$$;

-- ======================================== 12. legal texts with blanks
-- The check only caught three or more capitals in brackets, so "[adresse]",
-- "[X]" and "[À VALIDER : …]" -- all present in the seeded mandate -- went
-- live and would have been signed. Anything in brackets now counts, except a
-- Markdown link, which is "[text](url)".
create or replace function public.stamp_legal_document()
returns trigger
language plpgsql
as $$
begin
  new.sha256 := encode(digest(new.body, 'sha256'), 'hex');

  if new.active and new.body ~ '\[[^]\n]+\](?!\()' then
    raise exception
      'this document still contains placeholders and cannot be published: %',
      (regexp_match(new.body, '\[[^]\n]+\](?!\()'))[1]
      using errcode = '22023';
  end if;

  return new;
end;
$$;

-- ========================================== 13. deleting an account
-- Deletion only blanked a few fields and suspended the profile: the name
-- stayed, and the login still existed. Now the person is erased and the login
-- deleted. Invoices are kept for ten years, and they still say who they were
-- issued to, from the snapshot above, not from the profile.
--
-- profiles.id referenced auth.users with ON DELETE CASCADE, so deleting the
-- login would have tried to delete the profile, which invoices and leads
-- reference -- and the whole deletion would fail. The profile outlives the
-- login now, anonymised.
do $$
declare v_name text;
begin
  select conname into v_name
    from pg_constraint
   where conrelid = 'public.profiles'::regclass and contype = 'f'
     and confrelid = 'auth.users'::regclass;
  if v_name is not null then
    execute format('alter table public.profiles drop constraint %I', v_name);
  end if;
end $$;

create or replace function public.request_account_deletion()
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

  if is_admin(v_uid) and not exists (
       select 1 from profiles
        where role in ('admin', 'manager') and status = 'active' and id <> v_uid) then
    raise exception
      'you are the last administrator: appoint another before deleting this account'
      using errcode = '42501';
  end if;

  update profiles
     set status = 'suspended',
         first_name = 'Compte', last_name = 'supprimé',
         email = 'deleted+' || id::text || '@invalid',
         phone = null, avatar_url = null,
         company_name = null, siret = null, legal_form = null,
         address = null, postal_code = null, city = null,
         vat_liable = false, vat_number = null,
         bank_details_on_file = false, bank_details_reference = null,
         bank_details_updated_at = now()
   where id = v_uid;

  delete from personal_notes where author_id = v_uid;
  delete from device_tokens  where profile_id = v_uid;
  delete from notifications  where profile_id = v_uid;

  insert into audit_log (actor_id, entity, entity_id, action)
  values (v_uid, 'profiles', v_uid, 'account_deleted');

  -- Supabase lets the owner of this function delete the login. If a project
  -- ever refuses it, the deletion above still stands and the audit log says
  -- the login is left for an operator, rather than the whole request failing.
  begin
    delete from auth.users where id = v_uid;
  exception when insufficient_privilege or foreign_key_violation then
    insert into audit_log (actor_id, entity, entity_id, action)
    values (v_uid, 'auth.users', v_uid, 'auth_user_deletion_pending');
  end;
end;
$$;

-- ==================================== 14. who can call what, and counters
-- Postgres grants EXECUTE on every new function to PUBLIC, and nothing here
-- had ever revoked it. That included next_invoice_index(), which is SECURITY
-- DEFINER and takes no permission check: anybody, signed in or not, could
-- consume invoice numbers and put holes in a series the CGI requires to be
-- continuous. The counter table also let an admin rewind it.
--
-- Nothing runs for a caller with no account. A signed-in caller gets the
-- functions the app calls, which check their own caller; the numbering
-- function is reachable only through the insert trigger.
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated, service_role;
revoke execute on function public.next_invoice_index(int) from authenticated;

-- and for whatever a later migration adds
alter default privileges revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;
alter default privileges in schema public grant execute on functions to authenticated, service_role;

drop policy if exists invoice_seq_admin on invoice_sequences;
create policy invoice_seq_read on invoice_sequences for select to authenticated
  using ((select is_admin((select auth.uid()))));
