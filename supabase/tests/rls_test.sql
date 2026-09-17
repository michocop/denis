-- Energy Courtage — RLS & business-rule test suite.
-- Run with scripts/db_test.sh. Every check raises on failure, so a clean run
-- means every assertion below held.

\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function assert(p_condition boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_condition then
    raise notice '  PASS  %', p_label;
  else
    raise exception 'FAIL  %', p_label;
  end if;
end $$;

-- Asserts that running p_sql as p_uid is refused.
--
-- Two different denial shapes have to be caught here, and conflating them is
-- how authorisation tests end up green while the data is wide open:
--   * a guard trigger RAISEs  -> caught by the exception handler
--   * RLS filters the row out -> no error at all, simply 0 rows affected
-- ROW_COUNT is read via GET DIAGNOSTICS because EXECUTE does NOT update FOUND.
create or replace function assert_denied(p_uid uuid, p_sql text, p_label text)
returns void language plpgsql as $$
declare
  v_denied boolean := false;
  v_rows   bigint  := 0;
begin
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, true);
    execute p_sql;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then v_denied := true; end if;
  exception when others then
    v_denied := true;
  end;
  perform assert(v_denied, p_label);
end $$;

create or replace function login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid)::text, true);
$$;

-- ---------------------------------------------------------------- fixtures
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
begin
  insert into auth.users (id, email) values
    (v_johann, 'johann@example.test'),
    (v_marie,  'marie@example.test'),
    (v_pierre, 'pierre-louis@trinity-energie.test');

  insert into profiles (id, role, status, first_name, last_name, email, city,
                        company_name, billing_mandate_signed_at) values
    (v_johann, 'apporteur', 'active', 'Johann', 'Lefeuvre', 'johann@example.test', 'Lille',
     'Lefeuvre Conseil', timestamptz '2026-01-05 10:00'),
    -- Marie has no mandate on file: she cannot be invoiced (section 8)
    (v_marie,  'apporteur', 'active', 'Marie',  'Durand',   'marie@example.test',  'Lyon',
     null, null),
    (v_pierre, 'admin',     'active', 'Pierre-Louis', 'Tettamanti',
     'pierre-louis@trinity-energie.test', 'AIX-EN-PEVELE', 'Trinity Énergie', null);
end $$;

-- Johann creates a recommendation (Thomas Dubois, as in the screenshots)
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_first  uuid;
begin
  perform login(v_johann);
  select id into v_first from stages order by position limit 1;
  insert into recommendations
    (id, filleul_first_name, filleul_last_name, filleul_phone, parrain_id, current_stage_id)
  values
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Thomas', 'Dubois', '+33 6 75 75 75 75',
     v_johann, v_first);
end $$;

\echo ''
\echo '=== 1. Isolation between apporteurs ==============================='
set role authenticated;

do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  n int;
begin
  perform login(v_johann);
  select count(*) into n from recommendations;
  perform assert(n = 1, 'Johann sees his own recommendation');

  perform login(v_marie);
  select count(*) into n from recommendations;
  perform assert(n = 0, 'Marie cannot see Johann''s recommendation (the leak test)');

  select count(*) into n from profiles;
  perform assert(n = 1, 'Marie sees only her own profile, not the other users');

  perform login(v_pierre);
  select count(*) into n from recommendations;
  perform assert(n = 1, 'the admin sees every recommendation');
end $$;

\echo ''
\echo '=== 2. An apporteur cannot move his own pipeline =================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_reco   uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_last   uuid;
begin
  select id into v_last from stages order by position desc limit 1;

  perform assert_denied(v_johann,
    format('update recommendations set current_stage_id = %L where id = %L', v_last, v_reco),
    'Johann cannot advance his own recommendation');

  perform assert_denied(v_johann,
    format('update recommendations set reward_amount = 99999 where id = %L', v_reco),
    'Johann cannot set his own reward amount');

  perform assert_denied(v_johann,
    format('update recommendations set reward_status = ''paid'' where id = %L', v_reco),
    'Johann cannot mark himself as paid');

  perform assert_denied(v_johann,
    'select * from advance_stage(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'', ''devis_signe'')',
    'Johann cannot call advance_stage()');

  -- but he may still fix the filleul's phone number he typed in
  perform login(v_johann);
  update recommendations set filleul_phone = '+33 6 11 22 33 44' where id = v_reco;
  perform assert(found, 'Johann can still correct the filleul contact details he entered');
end $$;

\echo ''
\echo '=== 3. Admin advances the pipeline, templates render =============='
do $$
declare
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_txt    text;
  v_status reward_status;
begin
  perform login(v_pierre);
  update recommendations set reward_amount = 1000 where id = v_reco;

  perform advance_stage(v_reco, 'a_contacter');
  select comment into v_txt
    from recommendation_stage_events e join stages s on s.id = e.stage_id
   where e.recommendation_id = v_reco and s.key = 'a_contacter';
  perform assert(
    v_txt = 'Merci pour la mise en relation. Nous avons bien reçu les coordonnées de Thomas Dubois. Prochain point après le 1er échange.',
    'the "À contacter" template renders with the filleul name injected');

  perform advance_stage(v_reco, 'rdv_programme');
  perform advance_stage(v_reco, 'proposition_envoyee');

  select reward_status into v_status from recommendations where id = v_reco;
  perform assert(v_status = 'pending', 'reward is still pending before "Devis signé"');

  perform advance_stage(v_reco, 'devis_signe');
  select reward_status into v_status from recommendations where id = v_reco;
  perform assert(v_status = 'earned', 'reaching "Devis signé" earns the reward');

  perform advance_stage(v_reco, 'mission_terminee');
  select comment into v_txt
    from recommendation_stage_events e join stages s on s.id = e.stage_id
   where e.recommendation_id = v_reco and s.key = 'mission_terminee';
  perform assert(v_txt like 'Bonjour Johann,%' and v_txt like '%CERFA 2042 C%',
    'the final template greets the parrain and carries the BNC tax notice');
end $$;

\echo ''
\echo '=== 4. Invoice numbering is sequential and gapless ================'
do $$
declare
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_reco   uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_num    text;
begin
  perform login(v_pierre);
  insert into invoices (recommendation_id, apporteur_id, issuer_id, prestation_label,
                        intervened_on, issued_on, place, amount_ht, amount_ttc, legal_mentions)
  values (v_reco, v_johann, v_pierre, 'Apport d''affaires - mise en relation',
          date '2026-09-17', date '2026-09-17', 'AIX-EN-PEVELE', 300.00, 300.00,
          'TVA non applicable – Régime d''exonération de TVA (Article 293B du Code général des impôts)')
  returning number into v_num;
  perform assert(v_num = 'FA-2026-0001', 'first invoice of 2026 is numbered FA-2026-0001');

  -- a rolled-back insert must NOT consume a number, or the sequence has a gap
  begin
    insert into invoices (recommendation_id, apporteur_id, issuer_id, prestation_label,
                          intervened_on, issued_on, place, amount_ht, amount_ttc, legal_mentions)
    values (v_reco, v_johann, v_pierre, 'x', current_date, date '2026-09-18', 'X',
            -1, -1, 'x');   -- violates amount_ht > 0
  exception when check_violation then null;
  end;

  insert into invoices (recommendation_id, apporteur_id, issuer_id, prestation_label,
                        intervened_on, issued_on, place, amount_ht, amount_ttc, legal_mentions)
  values (v_reco, v_johann, v_pierre, 'Apport d''affaires - seconde prestation',
          date '2026-09-18', date '2026-09-18', 'AIX-EN-PEVELE', 150.00, 150.00, 'x')
  returning number into v_num;
  perform assert(v_num = 'FA-2026-0002',
    'a failed insert does not burn a number — the sequence stays gapless');
end $$;

\echo ''
\echo '=== 5. Signatures seal the invoice, which then cannot change ======'
do $$
declare
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_inv    uuid;
  v_status invoice_status;
  v_reward reward_status;
begin
  perform login(v_pierre);
  select id into v_inv from invoices where number = 'FA-2026-0001';

  update invoices set pdf_path = 'invoices/FA-2026-0001.pdf',
                      pdf_sha256 = repeat('a', 64)
   where id = v_inv;

  -- nobody may sign in another person's name
  perform assert_denied(v_marie, format(
    'insert into invoice_signatures (invoice_id, signer_id, signer_role, signer_full_name, document_sha256)
     values (%L, %L, ''apporteur'', ''Marie Durand'', %L)', v_inv, v_marie, repeat('a',64)),
    'Marie cannot sign an invoice that is not hers');

  perform assert_denied(v_johann, format(
    'insert into invoice_signatures (invoice_id, signer_id, signer_role, signer_full_name, document_sha256)
     values (%L, %L, ''entreprise'', ''Johann Lefeuvre'', %L)', v_inv, v_johann, repeat('a',64)),
    'Johann cannot sign in the company''s name');

  perform login(v_johann);
  insert into invoice_signatures (invoice_id, signer_id, signer_role, signer_full_name, document_sha256)
  values (v_inv, v_johann, 'apporteur', 'Johann Lefeuvre', repeat('a', 64));

  select status into v_status from invoices where id = v_inv;
  perform assert(v_status <> 'signed', 'one signature is not enough to seal the invoice');

  perform login(v_pierre);
  insert into invoice_signatures (invoice_id, signer_id, signer_role, signer_full_name, document_sha256)
  values (v_inv, v_pierre, 'entreprise', 'Pierre-Louis Tettamanti', repeat('a', 64));

  select status into v_status from invoices where id = v_inv;
  perform assert(v_status = 'signed', 'both signatures seal the invoice automatically');

  select reward_status into v_reward from recommendations
   where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  perform assert(v_reward = 'invoiced', 'sealing the invoice moves the reward to "invoiced"');

  perform assert_denied(v_pierre,
    format('update invoices set amount_ht = 5000 where id = %L', v_inv),
    'a sealed invoice cannot have its amount changed');

  perform assert_denied(v_pierre,
    format('update invoices set number = ''FA-2026-9999'' where id = %L', v_inv),
    'a sealed invoice cannot be renumbered');

  perform assert_denied(v_pierre,
    format('delete from invoices where id = %L', v_inv),
    'an invoice can never be deleted (10-year retention)');

  -- but it may still be marked as paid
  perform login(v_pierre);
  update invoices set status = 'paid' where id = v_inv;
  perform assert(found, 'a sealed invoice can still be marked paid');
end $$;

\echo ''
\echo '=== 6. "Supprimer" cannot orphan a legal document ================='
do $$
declare
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
begin
  perform assert_denied(v_pierre,
    format('delete from recommendations where id = %L', v_reco),
    'a recommendation carrying an invoice cannot be hard-deleted');

  perform assert_denied(v_pierre,
    format('select * from reset_pipeline(%L)', v_reco),
    '"Remettre à zéro" is refused once a signed invoice exists');

  -- soft delete remains available, and hides the row from its owner
  perform login(v_pierre);
  update recommendations set deleted_at = now() where id = v_reco;
  perform login('11111111-1111-1111-1111-111111111111');
  perform assert((select count(*) from recommendations) = 0,
    'a soft-deleted recommendation disappears from the apporteur''s list');
end $$;

\echo ''
\echo '=== 7. Private notes stay private ================================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
begin
  perform login(v_johann);
  insert into personal_notes (recommendation_id, author_id, body)
  values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_johann, 'Rappeler après les vacances');

  perform login(v_pierre);
  perform assert((select count(*) from personal_notes) = 0,
    'even an admin cannot read an apporteur''s "Notes personnelles"');
end $$;

\echo ''
\echo '=== 8. Invoicing obligations ======================================'
do $$
declare
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_reco   uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_inv    uuid;
  v_doc    jsonb;
  v_rate   numeric;
  v_ttc    numeric;
  v_ment   text;
begin
  perform login(v_pierre);

  -- no mandate on file -> refused, whatever the UI allows
  perform assert_denied(v_pierre, format(
    'insert into invoices (recommendation_id, apporteur_id, issuer_id, prestation_label,
                           intervened_on, issued_on, place, amount_ht, amount_ttc, legal_mentions)
     values (%L, %L, %L, ''x'', current_date, current_date, ''Lille'', 100, 100, ''x'')',
    v_reco, v_marie, v_pierre),
    'an apporteur without a self-billing mandate cannot be invoiced');

  -- a mandate signed after the invoice date is not a prior mandate
  update profiles set billing_mandate_signed_at = timestamptz '2027-01-01 10:00'
   where id = v_marie;
  perform assert_denied(v_pierre, format(
    'insert into invoices (recommendation_id, apporteur_id, issuer_id, prestation_label,
                           intervened_on, issued_on, place, amount_ht, amount_ttc, legal_mentions)
     values (%L, %L, %L, ''x'', current_date, date ''2026-09-17'', ''Lille'', 100, 100, ''x'')',
    v_reco, v_marie, v_pierre),
    'a mandate signed after the invoice date does not authorise it');

  -- Johann is under the franchise en base: 293B wording, no VAT
  select id into v_inv from invoices where number = 'FA-2026-0002';
  select vat_rate, amount_ttc, legal_mentions into v_rate, v_ttc, v_ment
    from invoices where id = v_inv;
  perform assert(v_rate = 0 and v_ttc = 150.00, 'a 293B apporteur is invoiced without VAT');
  perform assert(v_ment like '%Article 293B%', 'the 293B exemption wording is applied');

  -- once he crosses the threshold, VAT appears with no code change
  update profiles set vat_liable = true, vat_number = 'FR12345678901' where id = v_johann;
  insert into invoices (recommendation_id, apporteur_id, issuer_id, prestation_label,
                        intervened_on, issued_on, place, amount_ht, amount_ttc, legal_mentions)
  values (v_reco, v_johann, v_pierre, 'Apport d''affaires', date '2026-09-19',
          date '2026-09-19', 'AIX-EN-PEVELE', 300.00, 0, 'ignored')
  returning id, vat_rate, amount_ttc into v_inv, v_rate, v_ttc;
  perform assert(v_rate = 20.00 and v_ttc = 360.00,
    'a VAT-liable apporteur is invoiced with 20% VAT, derived not typed');

  -- the document contract the PDF and the in-app viewer both read
  select invoice_document(v_inv) into v_doc;
  perform assert(v_doc -> 'attestation' ->> 'avec' = 'Thomas Dubois',
    'the attestation names the filleul');
  perform assert(v_doc -> 'attestation' ->> 'mis_en_relation' = 'Trinity Énergie',
    'the attestation names the company');
  perform assert(v_doc -> 'amount' ->> 'ttc' = '360.00', 'the document carries the TTC amount');
  perform assert(v_doc ->> 'tax_notice' like '%CERFA 2042 C%',
    'the document carries the BNC tax notice');
  perform assert(jsonb_array_length(v_doc -> 'signatures') = 2
                 and (v_doc -> 'signatures' -> 0 ->> 'signed') = 'false',
    'both signature slots are present and start unsigned');

  update profiles set vat_liable = false, vat_number = null where id = v_johann;
end $$;

\echo ''
\echo '=== 9. The feed view does not bypass RLS =========================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_row    recommendation_feed%rowtype;
  n int;
begin
  -- section 6 soft-deleted the first reco; give Johann a live one again
  perform login(v_pierre);
  update recommendations set deleted_at = null
   where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

  perform login(v_marie);
  select count(*) into n from recommendation_feed;
  perform assert(n = 0, 'the feed view honours RLS: Marie still sees nothing');

  perform login(v_johann);
  select * into v_row from recommendation_feed limit 1;
  perform assert(v_row.parrain_name = 'Johann Lefeuvre', 'the feed resolves the parrain name');
  perform assert(jsonb_array_length(v_row.events) = 5,
    'the feed returns the whole timeline in one row (no N+1)');
  perform assert(v_row.events -> 0 ->> 'stage_key' = 'a_contacter',
    'timeline events come back in pipeline order');
  perform assert(v_row.invoice_number = 'FA-2026-0003', 'the feed exposes the latest invoice');
end $$;

\echo ''
\echo '=== 10. Dashboard stats are scoped to the caller =================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_stats  jsonb;
begin
  perform login(v_johann);
  select dashboard_stats() into v_stats;
  perform assert((v_stats ->> 'active_count')::int = 1, 'Johann counts his own recommendation');
  perform assert((v_stats ->> 'earned_total')::numeric = 1000,
    'his earned total reflects the invoiced reward');

  perform login(v_marie);
  select dashboard_stats() into v_stats;
  perform assert((v_stats ->> 'active_count')::int = 0,
    'Marie''s dashboard cannot count other people''s deals');
  perform assert((v_stats ->> 'earned_total')::numeric = 0, 'nor their money');
end $$;

reset role;
\echo ''
\echo '=== ALL ASSERTIONS PASSED ========================================='
