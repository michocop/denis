-- Energy Courtage — things that existed but could not be reached.
--
-- Found by asking, of every capability, "what calls this?" rather than by
-- reading the migration list.

-- ------------------------------------------------------- the commission
-- reward_amount was rendered on the card, the detail screen, the statement
-- and the dashboard totals, and there was no way to set it: no RPC, no
-- repository call, no field. Which also made issue_invoice() unusable, since
-- it refuses a recommendation with no agreed amount -- so the entire
-- invoicing chain was unreachable from the app for a second reason.
--
-- It is an RPC rather than a column write so that the rules live in one place:
-- only an admin, never after the invoice exists (the invoice copies the
-- amount, and changing it afterwards would make the two disagree), and the
-- change is in the audit log because it is the number the apporteur is paid.
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

  if exists (select 1 from invoices
              where recommendation_id = p_recommendation_id and status <> 'void') then
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

-- --------------------------------------------------------- signing out
-- forget_device_token existed with no caller, so a token stayed attached to
-- whoever registered it. On a shared or resold phone the next person to sign
-- in would receive the previous one's notifications -- the apporteur's
-- commissions, on someone else's lock screen.
--
-- The client cannot always hand the token back at sign-out (it may not have
-- one in memory), so this clears every token for the caller instead.
create or replace function public.forget_my_device_tokens()
returns void
language sql
as $$
  delete from device_tokens where profile_id = auth.uid();
$$;
