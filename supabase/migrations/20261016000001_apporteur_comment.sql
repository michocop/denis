-- ============================================ the apporteur's own words
-- The form had no room for what the apporteur knows and the fields do not
-- say: "contrat chez Engie jusqu'en mars", "joignable après 18 h", "c'est
-- son associé qui décide". That went into a phone call or was lost.
--
-- One free-text comment, written with the lead and read by whoever works it.
-- It is NOT a personal note: personal_notes stay private to their author,
-- this is addressed to the company. It is about the filleul, so it is
-- personal data like the rest of the row: erased with them and part of what
-- they get back on an access request.
alter table recommendations
  add column apporteur_comment text
  constraint reco_apporteur_comment_length
    check (apporteur_comment is null or char_length(apporteur_comment) <= 2000);

-- Appended last: CREATE OR REPLACE VIEW may only add columns at the end, and
-- recommendation_page() returns this row type.
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
  ) as pending_reminders,
  r.apporteur_comment
from recommendations r
join profiles p on p.id = r.parrain_id
join stages   s on s.id = r.current_stage_id
where r.deleted_at is null;

-- Anonymising clears the comment with the rest of the filleul's details.
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
         filleul_siret = null, filleul_address = null,
         apporteur_comment = null
   where id = p_recommendation_id;

  insert into audit_log (actor_id, entity, entity_id, action, after)
  values (auth.uid(), 'recommendations', p_recommendation_id, 'anonymise_filleul',
          jsonb_build_object('reason', p_reason, 'documents', cardinality(v_paths)));
  return v_paths;
end;
$$;

-- And an access request returns it.
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
      'apporteur_comment', r.apporteur_comment,
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
