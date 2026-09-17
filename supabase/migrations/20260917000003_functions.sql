-- Energy Courtage — functions.
-- Everything security-sensitive is SECURITY DEFINER with a pinned search_path
-- so it cannot be hijacked by a caller-controlled schema.

-- ------------------------------------------------------------ role helpers
-- SECURITY DEFINER on purpose: profiles has RLS, and a policy that queried
-- profiles through RLS would recurse infinitely.
create or replace function public.is_admin(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from profiles
    where id = p_uid and role in ('admin','manager') and status = 'active'
  );
$$;

create or replace function public.is_active_member(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from profiles where id = p_uid and status = 'active');
$$;

-- --------------------------------------------------------------- templates
-- Renders "Bonjour {parrain}, ... {filleul} ..." against a jsonb of values.
create or replace function public.render_template(p_template text, p_vars jsonb)
returns text
language plpgsql
immutable
as $$
declare
  k text;
  out_text text := coalesce(p_template, '');
begin
  for k in select jsonb_object_keys(p_vars) loop
    out_text := replace(out_text, '{' || k || '}', coalesce(p_vars ->> k, ''));
  end loop;
  return out_text;
end;
$$;

-- --------------------------------------------------------------- bookkeeping
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ------------------------------------------------- gapless invoice numbering
-- Art. 242 nonies A ann. II CGI requires a continuous, chronological sequence.
-- The UPDATE takes a row lock, which serialises concurrent issuers and makes
-- the sequence gapless — a plain Postgres SEQUENCE would NOT (it leaks numbers
-- on rollback).
create or replace function public.next_invoice_index(p_year int)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_index int;
begin
  insert into invoice_sequences (year, last_index)
  values (p_year, 0)
  on conflict (year) do nothing;

  update invoice_sequences
     set last_index = last_index + 1
   where year = p_year
  returning last_index into v_index;

  return v_index;
end;
$$;

-- ------------------------------------------------------- pipeline advance
-- "Valider l'étape". Admin-only, transactional, writes the timeline event,
-- moves the reco and flips the reward when the stage is the trigger.
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

  select * into v_parrain from profiles where id = v_reco.parrain_id;

  -- the admin may override the copy; otherwise the stage template is rendered
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

-- "Remettre à zéro" — reverts the timeline without destroying history.
create or replace function public.reset_pipeline(p_recommendation_id uuid)
returns recommendations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_first uuid;
  v_reco  recommendations%rowtype;
begin
  if not is_admin(v_actor) then
    raise exception 'only an admin may reset a recommendation' using errcode = '42501';
  end if;

  if exists (select 1 from invoices
              where recommendation_id = p_recommendation_id
                and status in ('signed','paid')) then
    raise exception 'cannot reset a recommendation that carries a signed invoice'
      using errcode = '42501';
  end if;

  update recommendation_stage_events
     set reverted_at = now(), reverted_by = v_actor
   where recommendation_id = p_recommendation_id and reverted_at is null;

  select id into v_first from stages order by position limit 1;

  update recommendations
     set current_stage_id = v_first,
         reward_status    = 'pending'
   where id = p_recommendation_id
  returning * into v_reco;

  insert into audit_log (actor_id, entity, entity_id, action)
  values (v_actor, 'recommendations', p_recommendation_id, 'reset_pipeline');

  return v_reco;
end;
$$;
