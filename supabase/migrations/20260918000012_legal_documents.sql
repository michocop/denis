-- Energy Courtage — the documents people actually agree to.
--
-- The app had a button labelled "Signer le mandat" under a two-line summary,
-- and tapping it set a timestamp. The document was never shown. That is not a
-- mandate: self-billing under art. 289, I-2 du CGI requires a PRIOR WRITTEN
-- mandate, and a consent recorded without presenting the text it consents to
-- is worth nothing if it is ever challenged. The same applies to the CGU and
-- the privacy policy, which the App Store also requires be presented.
--
-- So the text lives in the database, versioned, and what is recorded is which
-- version was accepted and the digest of the exact bytes -- the same discipline
-- invoices already use, for the same reason: what was agreed to must be
-- reconstructible years later.

create table legal_documents (
  key          text not null,
  version      text not null,
  title        text not null,
  body         text not null,
  sha256       text not null,
  published_at timestamptz not null default now(),
  active       boolean not null default false,
  primary key (key, version)
);

-- One live version per document. An older one is kept, never deleted: somebody
-- signed it, and their acceptance has to stay readable.
create unique index legal_documents_one_active
  on legal_documents (key) where active;

alter table legal_documents enable row level security;

-- Everyone signed in can read what they are being asked to agree to. Only an
-- admin can publish.
create policy legal_documents_read on legal_documents for select to authenticated
  using (true);
create policy legal_documents_write on legal_documents for all to authenticated
  using ((select is_admin((select auth.uid()))))
  with check ((select is_admin((select auth.uid()))));

grant select, insert, update, delete on legal_documents to authenticated;

-- The digest is derived, never supplied: a caller-provided hash of a document
-- it also supplied proves nothing.
create or replace function public.stamp_legal_document()
returns trigger
language plpgsql
as $$
begin
  new.sha256 := encode(digest(new.body, 'sha256'), 'hex');

  -- A draft still carrying [PLACEHOLDERS] must never go live. Somebody would
  -- otherwise sign a contract with "[RAISON SOCIALE]" where the company's name
  -- belongs, and the signature would be the only real thing in it.
  if new.active and new.body ~ '\[[A-ZÉÈÀÇ_ /]{3,}\]' then
    raise exception
      'this document still contains placeholders and cannot be published: %',
      (regexp_match(new.body, '\[[A-ZÉÈÀÇ_ /]{3,}\]'))[1]
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger legal_documents_stamp before insert or update on legal_documents
  for each row execute function public.stamp_legal_document();

-- ------------------------------------------------------------- acceptances
-- One row per person per document version. Kept forever: it is the evidence.
create table legal_acceptances (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references profiles(id) on delete restrict,
  key         text not null,
  version     text not null,
  sha256      text not null,
  full_name   text not null,
  accepted_at timestamptz not null default now(),
  ip_address  inet,
  user_agent  text,
  unique (profile_id, key, version),
  foreign key (key, version) references legal_documents (key, version)
);

alter table legal_acceptances enable row level security;

create policy legal_acceptances_own on legal_acceptances for select to authenticated
  using (profile_id = (select auth.uid())
         or (select is_admin((select auth.uid()))));

-- Inserted only through accept_legal_document(), which checks the digest.
grant select on legal_acceptances to authenticated;

create index legal_acceptances_profile_idx on legal_acceptances (profile_id, key);

alter table profiles
  add column billing_mandate_version text,
  add column billing_mandate_sha256  text;

-- ------------------------------------------------------------ accepting one
-- The digest is what binds: the client sends back the hash of the text it
-- actually displayed, and a mismatch means the person agreed to something
-- other than what is published. Exactly the rule sign_invoice() applies.
create or replace function public.accept_legal_document(
  p_key        text,
  p_sha256     text,
  p_ip         inet default null,
  p_user_agent text default null
)
returns legal_acceptances
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := auth.uid();
  v_doc  legal_documents%rowtype;
  v_name text;
  v_row  legal_acceptances%rowtype;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into v_doc from legal_documents where key = p_key and active;
  if not found then
    raise exception 'no published version of %', p_key using errcode = 'P0002';
  end if;

  if v_doc.sha256 is distinct from p_sha256 then
    raise exception
      'the document accepted does not match the published one'
      using errcode = '22023';
  end if;

  select first_name || ' ' || last_name into v_name from profiles where id = v_uid;
  if v_name is null then
    raise exception 'no profile for this account' using errcode = 'P0002';
  end if;

  insert into legal_acceptances (profile_id, key, version, sha256, full_name,
                                 ip_address, user_agent)
  values (v_uid, p_key, v_doc.version, v_doc.sha256, v_name, p_ip, p_user_agent)
  on conflict (profile_id, key, version) do update set accepted_at = excluded.accepted_at
  returning * into v_row;

  -- the mandate is the one with a downstream effect: it gates invoicing.
  -- guard_mandate_columns refuses this write from a client; the flag below is
  -- what tells it this is the sanctioned path rather than a PATCH.
  if p_key = 'mandat_facturation' then
    perform set_config('app.recording_mandate', 'on', true);
    update profiles
       set billing_mandate_signed_at = coalesce(billing_mandate_signed_at, now()),
           billing_mandate_version   = v_doc.version,
           billing_mandate_sha256    = v_doc.sha256
     where id = v_uid;
    perform set_config('app.recording_mandate', 'off', true);
  end if;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (v_uid, 'legal_acceptances', v_row.id, 'accept_legal_document',
          jsonb_build_object('key', p_key, 'version', v_doc.version));

  return v_row;
end;
$$;

-- What the app shows, and what it still owes. Returns one row per document
-- with the live text and whether this reader has accepted THIS version --
-- a revised mandate has to be signed again, which is the whole point of
-- versioning it.
create view legal_documents_for_me with (security_invoker = true) as
select
  d.key,
  d.version,
  d.title,
  d.body,
  d.sha256,
  d.published_at,
  exists (
    select 1 from legal_acceptances a
     where a.profile_id = (select auth.uid())
       and a.key = d.key and a.version = d.version
  ) as accepted
from legal_documents d
where d.active;

grant select on legal_documents_for_me to authenticated;

-- signBillingMandate() used to flip a timestamp with no document behind it.
-- Kept as a thin wrapper so nothing calls the old shape by accident.
drop function if exists public.sign_billing_mandate();

-- ------------------------------------------- the mandate columns are derived
-- profiles_update lets anyone edit their own row, which included
-- billing_mandate_signed_at -- so the client could grant itself a mandate with
-- a PATCH and skip the document entirely. That is exactly what the old
-- signBillingMandate() did. These three columns are now set only by
-- accept_legal_document(), which runs as definer and checks the digest.
create or replace function public.guard_mandate_columns()
returns trigger
language plpgsql
as $$
begin
  -- auth.uid() is null for trusted server contexts (the definer function and
  -- the seed), which is the same convention guard_recommendation_columns uses.
  if auth.uid() is null
     or coalesce(current_setting('app.recording_mandate', true), 'off') = 'on' then
    return new;
  end if;

  if new.billing_mandate_signed_at is distinct from old.billing_mandate_signed_at
     or new.billing_mandate_version is distinct from old.billing_mandate_version
     or new.billing_mandate_sha256  is distinct from old.billing_mandate_sha256 then
    raise exception
      'the mandate is recorded by accepting the document, not by writing this column'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger profiles_guard_mandate before update on profiles
  for each row execute function public.guard_mandate_columns();
