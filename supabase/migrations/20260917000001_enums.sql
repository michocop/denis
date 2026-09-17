-- Energy Courtage — enumerated types
-- All domain state machines live here so the app can never invent a state.

create type user_role        as enum ('apporteur', 'admin', 'manager');
create type profile_status   as enum ('pending', 'active', 'suspended');
create type kyc_status       as enum ('none', 'submitted', 'approved', 'rejected');

create type reco_status      as enum ('active', 'archived_won', 'archived_lost');
create type reward_status    as enum ('pending', 'earned', 'invoiced', 'paid', 'cancelled');

create type invoice_status   as enum ('draft', 'awaiting_signatures', 'signed', 'paid', 'void');
create type signature_role   as enum ('apporteur', 'entreprise');
create type vat_regime       as enum ('franchise_293b', 'standard');

create type price_mode       as enum ('quote', 'fixed');
create type document_type    as enum ('invoice', 'quote', 'contract', 'other');

create type thread_kind      as enum ('direct', 'group', 'ticket');
create type ticket_status    as enum ('open', 'pending', 'resolved', 'closed');
create type ticket_priority  as enum ('low', 'normal', 'high', 'urgent');

create type reminder_status  as enum ('scheduled', 'sent', 'done', 'cancelled');
create type reminder_channel as enum ('push', 'email');
