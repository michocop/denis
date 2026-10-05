-- Energy Courtage — say where the contract is.
--
-- The banner on the last two stages pointed to an "onglet Documents" the app
-- does not have: a lead's documents are in the lead's own detail.
update stages
   set banner_template = 'Contrat signé. Retrouvez-le dans les documents de la recommandation.'
 where banner_template = 'Contrat signé. Disponible dans l''onglet Documents';

-- Amounts in notifications were the database's own "300.00 EUR". Written the
-- French way now, as the app and the PDF write them: "12 500,00 €".
create or replace function public.format_euros(p_amount text)
returns text
language sql
immutable
as $$
  select case when p_amount is null or p_amount = '' then null else
    regexp_replace(replace(to_char(p_amount::numeric, 'FM999999999990.00'), '.', ','),
                   '(\d)(?=(\d{3})+,)', '\1 ', 'g') || ' €'
  end;
$$;

create or replace function public.notification_body(p_kind text, p_payload jsonb)
returns text
language sql
immutable
as $$
  select case p_kind
    when 'stage_advanced' then
      coalesce(p_payload ->> 'filleul', 'Votre filleul') || ' : '
      || coalesce(p_payload ->> 'stage_label', 'étape suivante')
    when 'reward_earned' then
      coalesce(p_payload ->> 'filleul', 'Votre filleul') || ' a signé'
      || coalesce(' — ' || format_euros(p_payload ->> 'amount'), '')
    when 'message_received' then coalesce(p_payload ->> 'excerpt', '')
    when 'invoice_ready' then
      'Facture ' || coalesce(p_payload ->> 'number', '')
      || coalesce(' — ' || format_euros(p_payload ->> 'amount'), '')
    when 'payment_sent' then
      coalesce(format_euros(p_payload ->> 'amount'), 'Votre paiement') || ' en route'
    when 'reminder_due' then
      coalesce(p_payload ->> 'label', 'Relance prévue')
      || coalesce(' — ' || (p_payload ->> 'filleul'), '')
    when 'lead_created' then
      coalesce(p_payload ->> 'filleul', 'Un filleul')
      || coalesce(', recommandé par ' || (p_payload ->> 'parrain'), '')
    when 'member_pending' then
      coalesce(p_payload ->> 'name', 'Un nouveau membre') || ' attend votre validation'
    when 'invoice_signed_by_apporteur' then
      coalesce(p_payload ->> 'apporteur', 'L''apporteur') || ' a signé la facture '
      || coalesce(p_payload ->> 'number', '')
    when 'document_added' then
      coalesce(p_payload ->> 'filename', 'Un document')
      || coalesce(' — ' || (p_payload ->> 'filleul'), '')
    else ''
  end;
$$;

revoke execute on function public.format_euros(text) from public, anon;
grant execute on function public.format_euros(text) to authenticated, service_role;
