-- Demo data for a local or staging project. Never run against production.
--
-- Creates the three people from the screenshots, a recommendation mid-pipeline
-- and a completed one with an invoice, so every state the UI renders has
-- something to render.
--
-- Auth users must exist first. On a real Supabase project create them through
-- the dashboard or the admin API, then run this with their ids.

\set johann '11111111-1111-1111-1111-111111111111'
\set marie  '22222222-2222-2222-2222-222222222222'
\set pierre '33333333-3333-3333-3333-333333333333'

insert into profiles (id, role, status, first_name, last_name, email, phone,
                      company_name, city, billing_mandate_signed_at)
values
  (:'johann', 'apporteur', 'active', 'Johann', 'Lefeuvre', 'johann@example.test',
   '+33 6 11 11 11 11', 'Lefeuvre Conseil', 'Lille', now() - interval '6 months'),
  -- Marie has no mandate: the app should show her the notice, and invoicing
  -- her must fail.
  (:'marie', 'apporteur', 'active', 'Marie', 'Durand', 'marie@example.test',
   '+33 6 22 22 22 22', null, 'Lyon', null),
  (:'pierre', 'admin', 'active', 'Pierre-Louis', 'Tettamanti',
   'pierre-louis@trinity-energie.test', '+33 6 33 33 33 33',
   'Trinity Énergie', 'AIX-EN-PEVELE', null)
on conflict (id) do nothing;

-- Mid-pipeline: one stage done, one current, three ahead. No amount, no banner.
insert into recommendations (id, filleul_first_name, filleul_last_name, filleul_phone,
                             parrain_id, assigned_admin_id, reward_amount)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Thomas', 'Dubois',
        '+33 6 75 75 75 75', :'johann', :'pierre', 1000)
on conflict (id) do nothing;

insert into recommendation_stage_events (recommendation_id, stage_id, comment, completed_by)
select 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', s.id,
       render_template(s.comment_template,
                       jsonb_build_object('filleul', 'Thomas Dubois', 'parrain', 'Johann')),
       :'pierre'
from stages s where s.key = 'a_contacter'
on conflict do nothing;

update recommendations
   set current_stage_id = (select id from stages where key = 'rdv_programme')
 where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

-- Completed, with an invoice: exercises the banner, the amount, the contract
-- button and the signature panel.
insert into recommendations (id, filleul_first_name, filleul_last_name, filleul_phone,
                             parrain_id, assigned_admin_id, reward_amount)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Claire', 'Petit',
        '+33 6 44 44 44 44', :'johann', :'pierre', 300)
on conflict (id) do nothing;

insert into recommendation_stage_events (recommendation_id, stage_id, comment, completed_by)
select 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', s.id,
       render_template(s.comment_template,
                       jsonb_build_object('filleul', 'Claire Petit', 'parrain', 'Johann')),
       :'pierre'
from stages s
on conflict do nothing;

update recommendations
   set current_stage_id = (select id from stages order by position desc limit 1),
       reward_status = 'earned'
 where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

-- legal_mentions and the digest are both set by triggers; the value passed
-- here is replaced.
insert into invoices (recommendation_id, apporteur_id, issuer_id, prestation_label,
                      intervened_on, issued_on, place, amount_ht, amount_ttc, legal_mentions)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', :'johann', :'pierre',
        'Apport d''affaires - mise en relation', current_date, current_date,
        'AIX-EN-PEVELE', 300.00, 300.00, 'replaced by trigger')
on conflict do nothing;
