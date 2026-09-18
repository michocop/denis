-- Synthetic load for measuring, not for any real project.
-- 2 000 apporteurs, ~40 000 recommendations, their stage history, messages
-- and notifications: roughly what this looks like after a couple of busy years.
set client_min_messages = warning;

insert into auth.users (id, email)
select gen_random_uuid(), 'bench' || i || '@example.test' from generate_series(1, 2000) i;

insert into profiles (id, role, status, first_name, last_name, email,
                      billing_mandate_signed_at)
select u.id, 'apporteur', 'active', 'Prenom' || row_number() over (),
       'Nom' || row_number() over (), u.email, now() - interval '1 year'
from auth.users u
where u.email like 'bench%' and not exists (select 1 from profiles p where p.id = u.id);

-- 20 recommendations each, spread over two years
insert into recommendations (filleul_first_name, filleul_last_name, filleul_phone,
                             filleul_email, parrain_id, current_stage_id,
                             reward_amount, reward_status, status, created_at)
select
  'Filleul' || g,
  'Client' || g,
  '06' || lpad((random() * 99999999)::bigint::text, 8, '0'),
  'filleul' || g || '@example.test',
  p.id,
  (select id from stages order by random() limit 1),
  (array[300, 500, 750, 1000])[1 + floor(random() * 4)],
  (array['pending','earned','invoiced','paid'])[1 + floor(random() * 4)]::reward_status,
  (array['active','active','active','archived_won','archived_lost'])[1 + floor(random() * 5)]::reco_status,
  now() - (random() * interval '730 days')
from profiles p
cross join generate_series(1, 20) g
where p.email like 'bench%';

-- every recommendation has reached at least the first stage, most several
insert into recommendation_stage_events (recommendation_id, stage_id, comment, completed_by)
select r.id, s.id, 'Commentaire de test pour ' || r.filleul_first_name, r.parrain_id
from recommendations r
join lateral (
  select id from stages where position <= 1 + floor(random() * 5) order by position
) s on true
where r.filleul_email like 'filleul%';

analyze;
