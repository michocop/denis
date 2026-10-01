-- Energy Courtage — core tables.

-- ---------------------------------------------------------------- profiles
create table profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  role           user_role      not null default 'apporteur',
  status         profile_status not null default 'pending',
  first_name     text not null,
  last_name      text not null,
  email          text not null,
  phone          text,
  avatar_url     text,
  -- billing identity: an apporteur invoices the company, so he needs a full one
  company_name   text,
  siret          text,
  legal_form     text,
  address        text,
  postal_code    text,
  city           text,
  -- drives whether the invoice carries the 293B exemption or real VAT (§6.2)
  vat_liable     boolean not null default false,
  vat_number     text,
  iban_encrypted text,
  kyc_state      kyc_status not null default 'none',
  -- self-billing (auto-facturation) is only lawful with a prior mandate
  billing_mandate_signed_at timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint profiles_vat_number_required
    check (not vat_liable or vat_number is not null)
);

-- ------------------------------------------------------------------ stages
-- The pipeline is data, not code: labels, banners and comment templates are
-- editable from the back-office without shipping a new build.
create table stages (
  id                uuid primary key default gen_random_uuid(),
  key               text not null unique,
  label             text not null,
  position          int  not null unique,
  is_reward_trigger boolean not null default false,
  is_terminal       boolean not null default false,
  banner_template   text,
  comment_template  text,
  created_at        timestamptz not null default now()
);

-- --------------------------------------------------------- recommendations
create table recommendations (
  id                   uuid primary key default gen_random_uuid(),
  -- the filleul: a third party who never signed up. See RGPD notes (§6.3).
  filleul_first_name   text not null,
  filleul_last_name    text not null,
  filleul_phone        text,
  filleul_email        text,
  filleul_company      text,
  filleul_siret        text,
  filleul_address      text,
  -- consent is a legal prerequisite for storing the above
  consent_confirmed_at timestamptz not null default now(),

  parrain_id           uuid not null references profiles(id) on delete restrict,
  assigned_admin_id    uuid references profiles(id) on delete set null,
  current_stage_id     uuid not null references stages(id),

  reward_amount        numeric(10,2),
  reward_status        reward_status not null default 'pending',
  status               reco_status   not null default 'active',

  archived_at          timestamptz,
  deleted_at           timestamptz,           -- soft delete only (§6.2)
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint reco_reward_amount_positive check (reward_amount is null or reward_amount >= 0)
);

create index on recommendations (parrain_id) where deleted_at is null;
create index on recommendations (assigned_admin_id) where deleted_at is null;
create index on recommendations (status, created_at desc) where deleted_at is null;

-- --------------------------------------------------- stage event timeline
-- One row per stage reached. This IS the timeline the app draws, and the
-- audit trail at the same time. "Remettre à zéro" sets reverted_at; it never
-- deletes rows.
create table recommendation_stage_events (
  id                uuid primary key default gen_random_uuid(),
  recommendation_id uuid not null references recommendations(id) on delete cascade,
  stage_id          uuid not null references stages(id),
  comment           text,
  completed_at      timestamptz not null default now(),
  completed_by      uuid not null references profiles(id),
  reverted_at       timestamptz,
  reverted_by       uuid references profiles(id)
);

create unique index reco_stage_event_unique_active
  on recommendation_stage_events (recommendation_id, stage_id)
  where reverted_at is null;

-- ---------------------------------------------------------------- invoices
create table invoice_sequences (
  year       int primary key,
  last_index int not null default 0
);

create table invoices (
  id                uuid primary key default gen_random_uuid(),
  recommendation_id uuid not null references recommendations(id) on delete restrict,
  apporteur_id      uuid not null references profiles(id) on delete restrict,
  issuer_id         uuid not null references profiles(id) on delete restrict,

  number            text not null unique,      -- gapless & sequential (§6.2)
  sequence_year     int  not null,
  sequence_index    int  not null,

  prestation_label  text not null,
  intervened_on     date not null,
  issued_on         date not null default current_date,
  place             text not null,

  amount_ht         numeric(10,2) not null,
  vat_mode          vat_regime not null default 'franchise_293b',
  vat_rate          numeric(5,2) not null default 0,
  vat_amount        numeric(10,2) not null default 0,
  amount_ttc        numeric(10,2) not null,
  currency          char(3) not null default 'EUR',

  payment_method    text not null default 'Virement bancaire',
  legal_mentions    text not null,
  tax_notice        text,

  status            invoice_status not null default 'draft',
  pdf_path          text,
  pdf_sha256        text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint invoice_amount_positive check (amount_ht > 0),
  constraint invoice_sequence_unique unique (sequence_year, sequence_index),
  -- a signed invoice must carry the exact document that was signed
  constraint invoice_signed_needs_pdf
    check (status not in ('signed','paid') or (pdf_path is not null and pdf_sha256 is not null))
);

-- The evidence bundle. Without this the signature is decorative (§6.1).
create table invoice_signatures (
  id               uuid primary key default gen_random_uuid(),
  invoice_id       uuid not null references invoices(id) on delete restrict,
  signer_id        uuid not null references profiles(id),
  signer_role      signature_role not null,
  signer_full_name text not null,
  signed_at        timestamptz not null default now(),
  document_sha256  text not null,
  ip_address       inet,
  user_agent       text,
  otp_verified     boolean not null default false,
  unique (invoice_id, signer_role)
);

-- --------------------------------------------------------------- the rest
create table personal_notes (
  id                uuid primary key default gen_random_uuid(),
  recommendation_id uuid not null references recommendations(id) on delete cascade,
  author_id         uuid not null references profiles(id) on delete cascade,
  body              text not null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (recommendation_id, author_id)
);

create table documents (
  id                uuid primary key default gen_random_uuid(),
  recommendation_id uuid not null references recommendations(id) on delete cascade,
  kind              document_type not null default 'other',
  storage_path      text not null,
  filename          text not null,
  byte_size         bigint,
  uploaded_by       uuid not null references profiles(id),
  created_at        timestamptz not null default now()
);

create table reminders (
  id                uuid primary key default gen_random_uuid(),
  recommendation_id uuid not null references recommendations(id) on delete cascade,
  created_by        uuid not null references profiles(id),
  label             text not null,
  due_at            timestamptz not null,
  channel           reminder_channel not null default 'push',
  status            reminder_status  not null default 'scheduled',
  created_at        timestamptz not null default now()
);

create table threads (
  id                uuid primary key default gen_random_uuid(),
  kind              thread_kind not null default 'direct',
  title             text,
  recommendation_id uuid references recommendations(id) on delete set null,
  created_by        uuid not null references profiles(id),
  created_at        timestamptz not null default now()
);

create table thread_participants (
  thread_id    uuid not null references threads(id) on delete cascade,
  profile_id   uuid not null references profiles(id) on delete cascade,
  last_read_at timestamptz,
  pinned       boolean not null default false,
  archived     boolean not null default false,
  primary key (thread_id, profile_id)
);

create table messages (
  id              uuid primary key default gen_random_uuid(),
  thread_id       uuid not null references threads(id) on delete cascade,
  sender_id       uuid not null references profiles(id),
  body            text,
  attachment_path text,
  -- clock_timestamp(), not now(): now() is the transaction's start time, so
  -- messages written in the same transaction all share it and the "latest
  -- message" in a conversation becomes whichever one the planner happens to
  -- return. A message log wants the instant of the write.
  created_at      timestamptz not null default clock_timestamp(),
  constraint message_not_empty check (body is not null or attachment_path is not null)
);

-- id breaks the remaining tie, so ordering a conversation is a total order.
create index on messages (thread_id, created_at desc, id desc);

create table tickets (
  id          uuid primary key default gen_random_uuid(),
  thread_id   uuid not null references threads(id) on delete cascade,
  opener_id   uuid not null references profiles(id),
  assignee_id uuid references profiles(id),
  subject     text not null,
  status      ticket_status   not null default 'open',
  priority    ticket_priority not null default 'normal',
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);

create table notifications (
  id         uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  kind       text not null,
  payload    jsonb not null default '{}'::jsonb,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);

create table audit_log (
  id         bigserial primary key,
  actor_id   uuid references profiles(id),
  entity     text not null,
  entity_id  uuid,
  action     text not null,
  before     jsonb,
  after      jsonb,
  created_at timestamptz not null default now()
);
