-- Energy Courtage — "Validation de l'étape" on the reward stage.
--
-- Until now the commission was one number typed into the detail screen. The
-- real app asks for more when the reward stage is validated: the services the
-- filleul actually took (each with the turnover it brings and the reward it
-- earns, ticked when signed), a capped total, how the reward is paid, and a
-- word for the apporteur. All of it lands in one call, so the stage can never
-- be reached with half of it saved.

create type payout_method as enum ('virement', 'cheque', 'carte_cadeau', 'avoir_facture');

create or replace function public.payout_method_label(p payout_method)
returns text
language sql
immutable
as $$
  select case p
           when 'virement'      then 'Virement bancaire'
           when 'cheque'        then 'Chèque'
           when 'carte_cadeau'  then 'Carte cadeau'
           when 'avoir_facture' then 'Avoir sur facture'
         end;
$$;

alter table recommendations
  add column turnover_amount numeric(12,2),
  add column payout_method   payout_method;

-- ------------------------------------------------------------- the ceiling
-- "Montant maximum : 2000 EUR". A setting, not a constant, so the company can
-- change it from the console without a release.
create table reward_settings (
  id          boolean primary key default true,
  max_reward  numeric(10,2) not null default 2000 check (max_reward > 0),
  updated_at  timestamptz not null default now(),
  constraint reward_settings_singleton check (id)
);
insert into reward_settings default values;

alter table reward_settings enable row level security;
create policy reward_settings_read on reward_settings for select to authenticated using (true);
grant select on reward_settings to authenticated;

-- --------------------------------------------------------------- the lines
create table reward_lines (
  id                uuid primary key default gen_random_uuid(),
  recommendation_id uuid not null references recommendations(id) on delete cascade,
  position          int  not null,
  label             text not null check (btrim(label) <> ''),
  turnover          numeric(12,2) not null default 0 check (turnover >= 0),
  reward            numeric(10,2) not null default 0 check (reward >= 0),
  signed            boolean not null default false,
  created_at        timestamptz not null default now(),
  unique (recommendation_id, position)
);

alter table reward_lines enable row level security;

-- The apporteur sees how their reward was made up; the company sees all.
-- Nobody writes here directly: validate_reward_stage does, with its checks.
create policy reward_lines_select on reward_lines for select to authenticated
  using (exists (
    select 1 from recommendations r
     where r.id = recommendation_id
       and r.deleted_at is null
       and (r.parrain_id = auth.uid() or is_admin(auth.uid()))
  ));
grant select on reward_lines to authenticated;

-- ---------------------------------------------------------------- the call
-- p_lines: [{"label": "Mandat de vente", "turnover": 1300000, "reward": 1300, "signed": true}, ...]
create or replace function public.validate_reward_stage(
  p_recommendation_id uuid,
  p_stage_key         text,
  p_lines             jsonb,
  p_payout_method     payout_method,
  p_message           text default null
)
returns recommendations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid      uuid := auth.uid();
  v_stage    stages%rowtype;
  v_reco     recommendations%rowtype;
  v_max      numeric;
  v_line     jsonb;
  v_pos      int := 0;
  v_turnover numeric := 0;
  v_reward   numeric := 0;
  v_label    text;
  v_l_turn   numeric;
  v_l_rew    numeric;
  v_signed   boolean;
begin
  if not is_admin(v_uid) then
    raise exception 'only an administrator validates the reward stage' using errcode = '42501';
  end if;

  select * into v_stage from stages where key = p_stage_key;
  if not found or not v_stage.is_reward_trigger then
    raise exception 'this is not the reward stage' using errcode = '22023';
  end if;

  select * into v_reco from recommendations
   where id = p_recommendation_id and deleted_at is null
   for update;
  if not found then
    raise exception 'recommendation not found' using errcode = 'P0002';
  end if;

  if exists (select 1 from invoices
              where recommendation_id = p_recommendation_id and status <> 'void') then
    raise exception 'Cette recommandation est déjà facturée : corrigez-la par un avoir.'
      using errcode = '42501';
  end if;

  if p_payout_method is null then
    raise exception 'Choisissez comment la récompense est versée.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Ajoutez au moins une prestation.' using errcode = '22023';
  end if;

  delete from reward_lines where recommendation_id = p_recommendation_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_pos    := v_pos + 1;
    v_label  := btrim(coalesce(v_line ->> 'label', ''));
    v_signed := coalesce((v_line ->> 'signed')::boolean, false);
    begin
      v_l_turn := round(coalesce((v_line ->> 'turnover')::numeric, 0), 2);
      v_l_rew  := round(coalesce((v_line ->> 'reward')::numeric, 0), 2);
    exception when others then
      raise exception 'Prestation % : montant invalide.', v_pos using errcode = '22023';
    end;
    if v_label = '' then
      raise exception 'Prestation % : indiquez l''intitulé.', v_pos using errcode = '22023';
    end if;
    if v_l_turn < 0 or v_l_rew < 0 then
      raise exception 'Prestation % : les montants ne peuvent pas être négatifs.', v_pos
        using errcode = '22023';
    end if;

    insert into reward_lines (recommendation_id, position, label, turnover, reward, signed)
    values (p_recommendation_id, v_pos, v_label, v_l_turn, v_l_rew, v_signed);

    if v_signed then
      v_turnover := v_turnover + v_l_turn;
      v_reward   := v_reward + v_l_rew;
    end if;
  end loop;

  if v_reward <= 0 then
    raise exception 'Cochez au moins une prestation signée avec une récompense.' using errcode = '22023';
  end if;

  select max_reward into v_max from reward_settings;
  if v_reward > v_max then
    raise exception 'La récompense (% EUR) dépasse le montant maximum de % EUR.',
      to_char(v_reward, 'FM999999990.00'), to_char(v_max, 'FM999999990')
      using errcode = '22023';
  end if;

  update recommendations
     set reward_amount   = v_reward,
         turnover_amount = v_turnover,
         payout_method   = p_payout_method,
         updated_at      = now()
   where id = p_recommendation_id;

  insert into audit_log (actor_id, entity, entity_id, action, before, after)
  values (v_uid, 'recommendations', p_recommendation_id, 'validate_reward_stage',
          jsonb_build_object('amount', v_reco.reward_amount),
          jsonb_build_object('amount', v_reward, 'turnover', v_turnover,
                             'payout_method', p_payout_method, 'lines', p_lines));

  -- the message for the apporteur is the comment on the stage they will read
  return advance_stage(p_recommendation_id, p_stage_key, nullif(btrim(p_message), ''));
end;
$$;

revoke all on function public.validate_reward_stage(uuid, text, jsonb, payout_method, text) from public, anon;
grant execute on function public.validate_reward_stage(uuid, text, jsonb, payout_method, text) to authenticated;

-- What the detail screen shows: the lines, the totals, and how it is paid.
create or replace function public.reward_breakdown(p_recommendation_id uuid)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'turnover_amount', r.turnover_amount,
    'reward_amount',   r.reward_amount,
    'payout_method',   r.payout_method,
    'max_reward',      (select max_reward from reward_settings),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'label', l.label, 'turnover', l.turnover,
               'reward', l.reward, 'signed', l.signed) order by l.position)
        from reward_lines l where l.recommendation_id = r.id), '[]'::jsonb))
  from recommendations r
  where r.id = p_recommendation_id;  -- RLS on recommendations decides who sees it
$$;

grant execute on function public.reward_breakdown(uuid) to authenticated;

-- ------------------------------------------- the invoice says how it is paid
-- invoices.payment_method has always defaulted to "Virement bancaire". When
-- the reward stage chose otherwise, the invoice now says so. A BEFORE trigger,
-- so the digest stamped after insert covers the right text.
create or replace function public.invoice_payment_method_from_reco()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_method payout_method;
begin
  select payout_method into v_method from recommendations where id = new.recommendation_id;
  if v_method is not null then
    new.payment_method := payout_method_label(v_method);
  end if;
  return new;
end;
$$;

create trigger invoices_payment_method before insert on invoices
  for each row execute function public.invoice_payment_method_from_reco();
