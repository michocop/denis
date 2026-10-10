-- Energy Courtage — RLS & business-rule test suite.
-- Run with scripts/db_test.sh. Every check raises on failure, so a clean run
-- means every assertion below held.

\set ON_ERROR_STOP on
-- What PostgREST and the SQL editor see on Supabase (config.toml extra_search_path).
set search_path = public, extensions;
alter role authenticated set search_path = public, extensions;
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
                        company_name, billing_mandate_signed_at, address, postal_code) values
    (v_johann, 'apporteur', 'active', 'Johann', 'Lefeuvre', 'johann@example.test', 'Lille',
     'Lefeuvre Conseil', timestamptz '2026-01-05 10:00', '12 rue des Lilas', '59000'),
    -- Marie has no mandate on file: she cannot be invoiced (section 8)
    (v_marie,  'apporteur', 'active', 'Marie',  'Durand',   'marie@example.test',  'Lyon',
     null, null, '3 place Bellecour', '69002'),
    (v_pierre, 'admin',     'active', 'Pierre-Louis', 'Tettamanti',
     'pierre-louis@trinity-energie.test', 'AIX-EN-PEVELE', 'Trinity Énergie', null, null, null);

  -- the customer on every invoice (section 44)
  insert into billing_settings (legal_name, legal_form, share_capital, siren, rcs_city,
                                vat_number, address, postal_code, city)
  values ('Trinity Énergie', 'SAS', '10 000 €', '123456789', 'Lille',
          'FR12123456789', '1 rue de la Gare', '59310', 'Aix-en-Pévèle');
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
\echo '=== 2b. An unauthenticated caller reaches nothing ================='
do $$
declare n int;
begin
  -- The column guard treats a null uid as trusted server-side context, which
  -- is only safe because RLS stops an anonymous request before it gets there.
  perform set_config('request.jwt.claims', '', true);
  select count(*) into n from recommendations;
  perform assert(n = 0, 'an unauthenticated caller sees no recommendations');

  perform assert_denied(null,
    'update recommendations set reward_amount = 1 where true',
    'and cannot update one either, so the null-uid guard exposes nothing');
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
    -- zero, not -1: a negative amount became legal when credit notes arrived,
    -- so -1 no longer fails and this test silently stopped testing anything.
    values (v_reco, v_johann, v_pierre, 'x', current_date, date '2026-09-18', 'X',
            0, 0, 'x');   -- violates amount_ht <> 0
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
  values (v_inv, v_johann, 'apporteur', 'Johann Lefeuvre',
          (select document_sha256 from invoices where id = v_inv));

  select status into v_status from invoices where id = v_inv;
  perform assert(v_status <> 'signed', 'one signature is not enough to seal the invoice');

  perform login(v_pierre);
  insert into invoice_signatures (invoice_id, signer_id, signer_role, signer_full_name, document_sha256)
  values (v_inv, v_pierre, 'entreprise', 'Pierre-Louis Tettamanti',
          (select document_sha256 from invoices where id = v_inv));

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

  -- A mandate signed after the invoice date is not a prior mandate. Set with
  -- the guard temporarily lifted, because a client can no longer write this
  -- column at all -- accepting the document is the only way, and that stamps
  -- now(). Which is the point: this state is unreachable from the app.
  perform set_config('app.recording_mandate', 'on', true);
  update profiles set billing_mandate_signed_at = timestamptz '2027-01-01 10:00'
   where id = v_marie;
  perform set_config('app.recording_mandate', 'off', true);
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
  perform assert(length(v_doc ->> 'document_sha256') = 64,
    'the viewer receives the digest it must sign, rather than recomputing it');
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

\echo ''
\echo '=== 11. Admin operations and their side effects ==================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_new    recommendations%rowtype;
begin
  -- a new reco needs no stage: the database picks the entry point
  perform login(v_marie);
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id,
                               consent_confirmed_at)
  values ('Claire', 'Petit', v_marie, now())
  returning * into v_new;
  v_reco := v_new.id;
  perform assert(
    v_new.current_stage_id = (select id from stages order by position limit 1),
    'a new recommendation enters at the first stage without the client saying so');

  perform assert_denied(v_marie,
    format('select * from reassign_recommendation(%L, %L)', v_reco, v_pierre),
    'an apporteur cannot reassign');

  perform login(v_pierre);
  perform reassign_recommendation(v_reco, v_pierre);
  perform assert(
    (select assigned_admin_id from recommendations where id = v_reco) = v_pierre,
    'an admin can reassign');

  perform assert_denied(v_pierre,
    format('select * from reassign_recommendation(%L, %L)', v_reco, v_johann),
    'a recommendation cannot be assigned to a non-admin');

  -- losing a deal cancels a reward that was never invoiced
  perform advance_stage(v_reco, 'a_contacter');
  update recommendations set reward_amount = 500 where id = v_reco;
  perform advance_stage(v_reco, 'rdv_programme');
  perform advance_stage(v_reco, 'proposition_envoyee');
  perform advance_stage(v_reco, 'devis_signe');
  perform assert((select reward_status from recommendations where id = v_reco) = 'earned',
    'the reward is earned at "Devis signé"');

  perform archive_recommendation(v_reco, false);
  perform assert((select status from recommendations where id = v_reco) = 'archived_lost',
    'archiving as lost sets the archived_lost status');
  perform assert((select reward_status from recommendations where id = v_reco) = 'cancelled',
    'a lost deal cancels a reward that was never invoiced');

  -- "Supprimer" is always soft
  perform soft_delete_recommendation(v_reco);
  perform assert((select deleted_at from recommendations where id = v_reco) is not null,
    '"Supprimer" soft-deletes rather than destroying the row');
end $$;

\echo ''
\echo '=== 12. Signing binds to the document that was shown =============='
do $$
declare
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_inv    uuid;
  v_digest text;
begin
  perform login(v_pierre);
  select id into v_inv from invoices where number = 'FA-2026-0003';
  select document_sha256 into v_digest from invoices where id = v_inv;
  perform assert(v_digest is not null and length(v_digest) = 64,
    'every invoice is stamped with the digest of its own canonical text');

  perform assert_denied(v_johann,
    format('select * from sign_invoice(%L, %L)', v_inv, repeat('c', 64)),
    'signing a document whose hash does not match the invoice is refused');

  perform assert_denied(v_marie,
    format('select * from sign_invoice(%L, %L)', v_inv, v_digest),
    'a stranger to the invoice cannot sign it at all');

  perform login(v_johann);
  perform sign_invoice(v_inv, v_digest);
  perform assert(
    (select signer_role from invoice_signatures where invoice_id = v_inv) = 'apporteur',
    'the signer role is derived from who is calling, never chosen');
end $$;

\echo ''
\echo '=== 13. Conversations are private to their participants ==========='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_thread uuid;
  n int;
begin
  perform login(v_johann);
  select start_direct_thread(v_pierre) into v_thread;
  insert into messages (thread_id, sender_id, body)
  values (v_thread, v_johann, 'Bonjour, une question sur Thomas Dubois.');

  perform assert(start_direct_thread(v_pierre) = v_thread,
    'starting the same conversation twice reuses it');

  perform login(v_marie);
  select count(*) into n from messages;
  perform assert(n = 0, 'Marie cannot read a conversation she is not part of');
  select count(*) into n from threads;
  perform assert(n = 0, 'nor even see that it exists');

  perform login(v_pierre);
  select count(*) into n from messages where thread_id = v_thread;
  perform assert(n = 1, 'the other participant reads it');
  perform assert((unread_counts() ->> v_thread::text)::int = 1,
    'it counts as unread until opened');
  perform mark_thread_read(v_thread);
  perform assert(unread_counts() -> v_thread::text is null,
    'and stops counting once read');

  -- a ticket puts an admin in the conversation from the first message
  perform login(v_marie);
  select open_ticket('Problème de virement', 'Je n''ai pas reçu mon paiement.') into v_thread;
  perform assert((select count(*) from thread_participants where thread_id = v_thread) = 2,
    'a ticket is opened with an admin already on it');
  perform login(v_pierre);
  perform assert((select count(*) from tickets where thread_id = v_thread) = 1,
    'and appears in the admin''s ticket list');
end $$;

\echo ''
\echo '=== 14. Access is by invitation only ============================='
-- auth.users belongs to the auth schema, which the authenticated role cannot
-- write to; these stand in for accounts GoTrue would have created.
\echo ''
\echo '=== 15. Duplicate leads are caught before they become disputes ===='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_check  jsonb;
begin
  -- Johann already holds Thomas Dubois, entered as "+33 6 11 22 33 44"
  perform login(v_marie);
  select check_duplicate_filleul('06 11 22 33 44') into v_check;
  perform assert((v_check ->> 'held_by_someone_else')::boolean,
    'a differently formatted phone number still matches an existing lead');
  perform assert(not (v_check ->> 'already_yours')::boolean,
    'and Marie is told only that someone holds it, never who');

  perform login(v_johann);
  select check_duplicate_filleul('+33 6 11 22 33 44') into v_check;
  perform assert((v_check ->> 'already_yours')::boolean,
    'Johann is told it is his own existing lead');

  select check_duplicate_filleul('06 99 99 99 99') into v_check;
  perform assert(not (v_check ->> 'already_yours')::boolean
                 and not (v_check ->> 'held_by_someone_else')::boolean,
    'an unknown number is free to recommend');
end $$;

\echo ''
\echo '=== 16. The feed surfaces what an admin needs to chase ============'
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_row    recommendation_feed%rowtype;
begin
  perform login(v_johann);
  select * into v_row from recommendation_feed
   where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  perform assert(v_row.days_since_activity is not null and v_row.days_since_activity >= 0,
    'every card reports how long it has been sitting');
  perform assert(v_row.invoice_id is not null,
    'and carries the invoice id, so the viewer opens without a second lookup');

  insert into personal_notes (recommendation_id, author_id, body)
  values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_johann, 'Rappeler lundi')
  on conflict (recommendation_id, author_id) do update set body = excluded.body;

  select * into v_row from recommendation_feed
   where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  perform assert(v_row.has_note, 'the card knows the reader has a private note on it');

  -- has_note is per reader: an admin must not see that a note exists
  perform login(v_pierre);
  select * into v_row from recommendation_feed
   where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  perform assert(not v_row.has_note,
    'and an admin is not even told that the apporteur wrote one');
end $$;

\echo ''
\echo '=== 17. Stage changes notify the apporteur ========================'
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_n      int;
begin
  perform login(v_johann);
  insert into recommendations (id, filleul_first_name, filleul_last_name,
                               filleul_phone, parrain_id, consent_confirmed_at)
  values ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Luc', 'Martin',
          '0600000001', v_johann, now())
  returning id into v_reco;

  perform mark_notifications_read();

  -- the commission is the company's to set, not the apporteur's (section 33)
  perform login(v_pierre);
  perform set_reward_amount(v_reco, 750);
  perform advance_stage(v_reco, 'a_contacter');

  perform login(v_johann);
  perform assert(unread_notification_count() = 1,
    'advancing a stage notifies the apporteur');
  perform assert(
    (select kind from notifications where profile_id = v_johann and read_at is null) = 'stage_advanced',
    'an ordinary stage reads as stage_advanced');

  perform login(v_pierre);
  perform advance_stage(v_reco, 'rdv_programme');
  perform advance_stage(v_reco, 'proposition_envoyee');
  perform advance_stage(v_reco, 'devis_signe');

  perform login(v_johann);
  perform assert(
    exists (select 1 from notifications
             where profile_id = v_johann and kind = 'reward_earned' and read_at is null),
    'reaching the reward stage is a different kind of notification');

  -- Marie has notifications of her own from her own recommendation, so the
  -- question is not whether she has any but whether Johann's reach her.
  perform login(v_marie);
  select count(*) into v_n from notifications
   where payload ->> 'recommendation_id' = v_reco::text;
  perform assert(v_n = 0, 'one apporteur never receives another''s notifications');

  perform login(v_johann);
  perform mark_notifications_read();
  perform assert(unread_notification_count() = 0, 'and can be cleared');
end $$;

\echo ''
\echo '=== 18. Reminders and the commission statement ===================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  v_rem    reminders%rowtype;
  v_total  numeric;
begin
  perform assert_denied(v_johann,
    format('select * from schedule_reminder(%L, ''Relancer'', now() + interval ''2 days'')', v_reco),
    'an apporteur cannot schedule a reminder');

  perform login(v_pierre);
  perform assert_denied(v_pierre,
    format('select * from schedule_reminder(%L, ''Hier'', now() - interval ''1 day'')', v_reco),
    'a reminder in the past is refused');

  select * into v_rem from schedule_reminder(v_reco, 'Relancer Luc Martin',
                                             now() + interval '2 days');
  perform assert(v_rem.status = 'scheduled', 'an admin can schedule one');
  perform assert(
    (select pending_reminders from recommendation_feed where id = v_reco) = 1,
    'and the card shows it is pending');

  perform complete_reminder(v_rem.id);
  perform assert(
    (select pending_reminders from recommendation_feed where id = v_reco) = 0,
    'completing it clears the count');

  -- the statement an apporteur needs at tax time
  perform login(v_johann);
  select sum(reward_amount) into v_total from commission_statement
   where parrain_id = v_johann;
  perform assert(v_total > 0, 'the commission statement totals the earned rewards');
  perform assert(
    (select count(*) from commission_statement where parrain_id <> v_johann) = 0,
    'and shows nobody else''s');
end $$;

\echo ''
\echo '=== 19. Pagination and search behave at scale ====================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_n      int;
  v_first  recommendation_feed%rowtype;
  v_second recommendation_feed%rowtype;
begin
  -- Inserted as Johann, not as the admin: the insert policy requires
  -- parrain_id = auth.uid(), so an admin cannot file a recommendation in
  -- someone else's name. (Worth confirming with the client that this matches
  -- how they work -- a phoned-in referral would need a separate RPC.)
  perform login(v_johann);
  insert into recommendations (filleul_first_name, filleul_last_name, filleul_phone,
                               parrain_id, consent_confirmed_at)
  select 'Page', 'Test' || g, '0620000' || lpad(g::text, 3, '0'), v_johann, now()
  from generate_series(1, 25) g;

  -- An apporteur cannot backdate a lead (section 33), so spreading them over
  -- time is done as the admin.
  perform login(v_pierre);
  update recommendations
     set created_at = now() - (substr(filleul_last_name, 5)::int || ' hours')::interval
   where filleul_first_name = 'Page';
  select count(*) into v_n from recommendation_page(false, null, null, null, 20);
  perform assert(v_n = 20, 'a page is bounded, however many rows exist');

  select count(*) into v_n from recommendation_page(false, null, null, null, 5000);
  perform assert(v_n <= 100, 'and a caller cannot ask for the whole table');

  -- keyset: the next page starts strictly after the last row of the previous
  select * into v_first from recommendation_page(false, null, null, null, 1);
  select * into v_second
    from recommendation_page(false, null, v_first.created_at, v_first.id, 1);
  perform assert(v_second.id <> v_first.id,
    'the next page never repeats the row the cursor pointed at');
  perform assert(v_second.created_at <= v_first.created_at,
    'and continues in the same order');

  -- search reaches both sides of the relationship
  select count(*) into v_n from recommendation_page(false, 'Test7', null, null, 20);
  perform assert(v_n >= 1, 'search finds a filleul by name');

  select count(*) into v_n from recommendation_page(false, 'Lefeuvre', null, null, 20);
  perform assert(v_n >= 1, 'and finds recommendations by their apporteur''s name');

  -- the denormalised name has to stay true, or an apporteur vanishes
  perform login(v_johann);
  update profiles set last_name = 'Lefeuvre-Martin' where id = v_johann;
  perform login(v_pierre);
  select count(*) into v_n from recommendation_page(false, 'Lefeuvre-Martin', null, null, 20);
  perform assert(v_n >= 1, 'renaming an apporteur keeps their recommendations findable');
  perform login(v_johann);
  update profiles set last_name = 'Lefeuvre' where id = v_johann;

  -- and search still respects who is asking
  perform login('22222222-2222-2222-2222-222222222222');
  select count(*) into v_n from recommendation_page(false, 'Test7', null, null, 20);
  perform assert(v_n = 0, 'search never reaches another apporteur''s recommendations');
end $$;

\echo ''
\echo '=== 20. Paying, and managing members =============================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_signed uuid;
  v_draft  uuid;
  v_batch  payout_batches%rowtype;
  v_n      int;
begin
  perform login(v_pierre);
  -- FA-2026-0003 carries the apporteur's signature from section 12; the
  -- company's completes it and seals it.
  select id into v_signed from invoices where number = 'FA-2026-0003';
  perform sign_invoice(v_signed,
                       (select document_sha256 from invoices where id = v_signed));
  perform assert((select status from invoices where id = v_signed) = 'signed',
    'the second signature seals the invoice, making it payable');

  select id into v_draft from invoices where status not in ('signed','paid') limit 1;
  perform assert(
    (select count(*) from payable_invoices where invoice_id = v_signed) = 1,
    'a signed invoice appears on the payables list');

  -- an unsigned invoice must never be paid: the apporteur has not agreed to it
  perform assert_denied(v_pierre,
    format('select * from create_payout_batch(array[%L]::uuid[])', v_draft),
    'a batch containing an unsigned invoice is refused entirely');

  perform assert_denied(v_johann,
    format('select * from create_payout_batch(array[%L]::uuid[])', v_signed),
    'an apporteur cannot pay themselves');

  perform assert_denied(v_pierre,
    format('select * from create_payout_batch(array[%L]::uuid[])', v_signed),
    'nobody is paid before their payment details are on file');
  perform login(v_pierre);
  perform set_bank_details_on_file(v_johann, true, 'COMPTA-4471');

  select * into v_batch from create_payout_batch(array[v_signed], 'VIR-2026-09');
  perform assert(v_batch.total > 0, 'an admin pays a batch');
  perform assert(
    (select status from invoices where id = v_signed) = 'paid',
    'the invoice is marked paid');
  perform assert(
    (select reward_status from recommendations r
      join invoices i on i.recommendation_id = r.id where i.id = v_signed) = 'paid',
    'and so is the reward behind it');
  perform assert(
    (select count(*) from payable_invoices where invoice_id = v_signed) = 0,
    'and it drops off the payables list');

  perform login(v_johann);
  perform assert(
    exists (select 1 from notifications
             where profile_id = v_johann and kind = 'payment_sent'),
    'the apporteur is told the money is on its way');
  perform assert((select count(*) from commissions) >= 1,
    'and the commission line is theirs to see');

  perform login(v_marie);
  perform assert((select count(*) from commissions) = 0,
    'while another apporteur sees none of it');

  -- member management
  perform assert_denied(v_johann,
    format('select * from set_member_status(%L, ''suspended'')', v_marie),
    'an apporteur cannot suspend anyone');

  perform login(v_pierre);
  perform assert_denied(v_pierre,
    format('select * from set_member_status(%L, ''suspended'')', v_pierre),
    'and an admin cannot suspend themselves out of the building');

  perform set_member_status(v_marie, 'suspended');
  perform assert((select status from profiles where id = v_marie) = 'suspended',
    'an admin can suspend a member');

  select count(*) into v_n from member_overview;
  perform assert(v_n >= 3, 'the member list shows everyone to an admin');
  perform assert(
    (select total_recommendations from member_overview where id = v_johann) > 0,
    'with the activity that decides who to chase');

  perform login(v_johann);
  select count(*) into v_n from member_overview;
  perform assert(v_n = 1, 'an apporteur sees only themselves in it');

  perform login(v_pierre);
  perform set_member_status(v_marie, 'active');
end $$;

\echo ''
\echo '=== 21. Payment details are recorded, not held ===================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_cols   int;
begin
  -- the column that claimed encryption it never had must be gone
  select count(*) into v_cols from information_schema.columns
   where table_name = 'profiles' and column_name = 'iban_encrypted';
  perform assert(v_cols = 0, 'no column pretends to hold an encrypted IBAN');

  perform assert_denied(v_johann,
    format('select * from set_bank_details_on_file(%L, true)', v_johann),
    'an apporteur cannot mark themselves payable');

  perform login(v_pierre);
  perform set_bank_details_on_file(v_johann, true, 'COMPTA-4471');
  perform assert(
    (select bank_details_on_file from profiles where id = v_johann),
    'an admin records that details are held elsewhere');
  perform assert(
    (select bank_details_updated_at from profiles where id = v_johann) is not null,
    'and when it was recorded');
end $$;

\echo ''
\echo '=== 22. The chat list has something to show ======================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_thread uuid;
  v_row    thread_overview%rowtype;
  n int;
begin
  perform login(v_johann);
  select start_support_thread() into v_thread;
  insert into messages (thread_id, sender_id, body)
  values (v_thread, v_johann, 'Bonjour, une question sur Thomas Dubois.');

  perform login(v_pierre);
  insert into messages (thread_id, sender_id, body)
  values (v_thread, v_pierre, 'Je vous réponds tout de suite.');

  perform login(v_johann);
  select * into v_row from thread_overview where id = v_thread;
  perform assert(v_row.counterpart_name = 'Pierre-Louis Tettamanti',
    'a direct conversation is named after the other person, not yourself');
  perform assert(v_row.last_message = 'Je vous réponds tout de suite.',
    'the row carries the latest message');
  perform assert(v_row.unread_count = 1,
    'and counts only what the reader has not seen');

  -- the author's name has to survive the join, or the bubble is anonymous
  perform assert(
    (select sender_name from message_feed
      where thread_id = v_thread order by created_at desc limit 1)
      = 'Pierre-Louis Tettamanti',
    'an apporteur can read the name of the admin writing to them');

  perform mark_thread_read(v_thread);
  select * into v_row from thread_overview where id = v_thread;
  perform assert(v_row.unread_count = 0, 'opening it clears the count');

  perform set_thread_flags(v_thread, p_pinned => true);
  select * into v_row from thread_overview where id = v_thread;
  perform assert(v_row.pinned, 'pinning is recorded for this reader');

  perform login(v_pierre);
  select * into v_row from thread_overview where id = v_thread;
  perform assert(not v_row.pinned,
    'and not for the other one: pinning is per reader, not per thread');
  perform assert(v_row.counterpart_name = 'Johann Lefeuvre',
    'each side sees the conversation named after the other');

  perform login(v_marie);
  select count(*) into n from thread_overview where id = v_thread;
  perform assert(n = 0, 'someone outside the conversation sees nothing of it');
  select count(*) into n from message_feed where thread_id = v_thread;
  perform assert(n = 0, 'not even the messages');
end $$;

reset role;
insert into auth.users (id, email) values
  ('44444444-4444-4444-4444-444444444444', 'nouveau@example.test'),
  ('55555555-5555-5555-5555-555555555555', 'autre@example.test');
set role authenticated;

do $$
declare
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_newbie uuid := '44444444-4444-4444-4444-444444444444';
  v_other  uuid := '55555555-5555-5555-5555-555555555555';
  v_invite invites%rowtype;
  v_state  jsonb;
  v_prof   profiles%rowtype;
begin
  perform assert_denied(v_johann,
    'select * from create_invite()',
    'an apporteur cannot mint invitations');

  perform login(v_pierre);
  select * into v_invite from create_invite('nouveau@example.test');
  perform assert(v_invite.code ~ '^[A-Z0-9-]{6,32}$',
    'the generated code is dictatable over the phone');
  perform assert(v_invite.role = 'apporteur',
    'the invitation carries the role, so a client cannot ask to be an admin');

  -- before redeeming, the app knows to show the invite screen
  perform login(v_newbie);
  select my_account_state() into v_state;
  perform assert(v_state ->> 'state' = 'needs_invite',
    'a registered account with no profile is asked for an invitation');

  perform assert_denied(v_newbie,
    'select * from redeem_invite(''NOPE-NOPE'', ''X'', ''Y'')',
    'a made-up code is refused');

  -- an invite addressed to someone else is not transferable
  perform assert_denied(v_other,
    format('select * from redeem_invite(%L, ''Autre'', ''Personne'')', v_invite.code),
    'an invitation locked to an address cannot be redeemed by anyone else');

  perform login(v_newbie);
  select * into v_prof from redeem_invite(v_invite.code, 'Nouveau', 'Venu');
  perform assert(v_prof.role = 'apporteur' and v_prof.status = 'active',
    'redeeming creates the profile with the invited role');

  select my_account_state() into v_state;
  perform assert(v_state ->> 'state' = 'ready', 'and the app can now show the tabs');

  perform assert_denied(v_newbie,
    format('select * from redeem_invite(%L, ''Encore'', ''Un'')', v_invite.code),
    'an invitation cannot be redeemed twice');

  -- a vetting invitation parks the member until an admin approves
  perform login(v_pierre);
  select * into v_invite from create_invite('autre@example.test', 'apporteur', false);
  perform login(v_other);
  perform redeem_invite(v_invite.code, 'Autre', 'Personne');
  select my_account_state() into v_state;
  perform assert(v_state ->> 'state' = 'pending_approval',
    'a vetting invitation leaves the member awaiting approval');

  perform assert((select count(*) from recommendations) = 0,
    'and a pending member reaches no data');
  perform assert_denied(v_other,
    'insert into recommendations (filleul_first_name, filleul_last_name, parrain_id)
     values (''X'', ''Y'', ''55555555-5555-5555-5555-555555555555'')',
    'nor can they create anything');

  perform assert_denied(v_other,
    format('select * from approve_member(%L)', v_other),
    'a pending member cannot approve themselves');

  perform login(v_pierre);
  perform approve_member(v_other);
  perform login(v_other);
  perform assert(my_account_state() ->> 'state' = 'ready',
    'an admin approval lets them in');
end $$;


\echo ''
\echo '=== 23. The invoice PDF is written once, by the server, and kept ='
set role authenticated;
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_sealed uuid;
  v_draft  uuid;
begin
  perform login(v_pierre);
  select id into v_sealed from invoices where number = 'FA-2026-0003';
  select id into v_draft from invoices where status not in ('signed','paid') limit 1;

  -- Nobody signed in records or uploads the ten-year copy any more: not the
  -- apporteur, who could file a doctored one, and not the company's phone,
  -- which only did it if someone happened to open the invoice.
  perform assert_denied(v_pierre,
    format('select retain_invoice_pdf(%L, %L, %L)', v_sealed, v_sealed || '.pdf', repeat('a', 64)),
    'not even the company records the retained document from the app');
  perform assert_denied(v_johann,
    format('select retain_invoice_pdf(%L, %L, %L)', v_sealed, v_sealed || '.pdf', repeat('a', 64)),
    'nor the apporteur');
  perform assert_denied(v_pierre,
    format('insert into storage.objects (bucket_id, name) values (%L, %L)',
           'invoices', v_sealed || '.pdf'),
    'and nobody signed in uploads into the invoices bucket');
  perform assert_denied(v_johann,
    format('insert into storage.objects (bucket_id, name) values (%L, %L)',
           'invoices', v_sealed || '.pdf'),
    'the apporteur least of all');
  perform assert(not has_function_privilege('authenticated',
                   'public.retain_invoice_pdf(uuid,text,text)', 'execute'),
    'the function that records it is the server''s alone');
end $$;

-- What the invoice-pdf function does, on the service role. Supabase grants
-- that role every table in public; the local stand-in has to be told.
reset role;
grant all on all tables in schema public to service_role;
set role service_role;
do $$
declare
  v_sealed uuid;
  v_draft  uuid;
  v_path   text;
begin
  select id into v_sealed from invoices where number = 'FA-2026-0003';
  select id into v_draft from invoices where status not in ('signed','paid') limit 1;

  begin
    perform retain_invoice_pdf(v_draft, v_draft || '.pdf', repeat('a', 64));
    perform assert(false, 'an unsigned invoice cannot be given a retained document');
  exception when sqlstate '42501' then
    perform assert(true, 'an unsigned invoice cannot be given a retained document');
  end;
  begin
    perform retain_invoice_pdf(v_sealed, 'elsewhere.pdf', repeat('a', 64));
    perform assert(false, 'it is filed under the invoice''s own name, nowhere else');
  exception when sqlstate '22023' then
    perform assert(true, 'it is filed under the invoice''s own name, nowhere else');
  end;

  select retain_invoice_pdf(v_sealed, v_sealed || '.pdf', repeat('a', 64)) into v_path;
  perform assert(v_path = v_sealed || '.pdf', 'the server records the file');
  perform assert((select pdf_sha256 from invoices where id = v_sealed) = repeat('a', 64),
    'and its digest, so a later download can be checked against it');

  select retain_invoice_pdf(v_sealed, v_sealed || '.pdf', repeat('b', 64)) into v_path;
  perform assert((select pdf_sha256 from invoices where id = v_sealed) = repeat('a', 64),
    'a second run returns the file already kept, and does not replace it');
end $$;
reset role;
-- the bytes themselves, as the function's storage client writes them
insert into storage.objects (bucket_id, name)
select 'invoices', id || '.pdf' from invoices where number = 'FA-2026-0003';
set role authenticated;

do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_sealed uuid;
begin
  perform login(v_pierre);
  select id into v_sealed from invoices where number = 'FA-2026-0003';
  perform assert_denied(v_pierre,
    format('update invoices set pdf_path = %L where id = %L', 'forged.pdf', v_sealed),
    'the path cannot be overwritten directly');
  perform assert_denied(v_pierre,
    format('update invoices set amount_ht = 1 where id = %L', v_sealed),
    'and the figures on a sealed invoice are still frozen');

  perform login(v_pierre);
  perform assert((select count(*) from storage.objects where name = v_sealed || '.pdf') = 1,
    'the company can read the retained file');
  perform login(v_johann);
  perform assert((select count(*) from storage.objects where name = v_sealed || '.pdf') = 1,
    'and so can the apporteur');
  perform login(v_marie);
  perform assert((select count(*) from storage.objects where name = v_sealed || '.pdf') = 0,
    'while another apporteur cannot see that it exists');
end $$;


\echo ''
\echo '=== 24. Notifications reach the right person ======================'
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_thread uuid;
  v_row    notification_feed%rowtype;
  n int;
begin
  perform login(v_johann);
  select start_support_thread() into v_thread;

  perform login(v_pierre);
  insert into messages (thread_id, sender_id, body)
  values (v_thread, v_pierre, 'Pouvez-vous rappeler Thomas Dubois ?');

  perform login(v_johann);
  select * into v_row from notification_feed
   where kind = 'message_received' order by created_at desc limit 1;
  perform assert(v_row.title = 'Pierre-Louis Tettamanti',
    'a message notifies the person it was sent to, titled with who sent it');
  perform assert(v_row.body = 'Pouvez-vous rappeler Thomas Dubois ?',
    'and carries enough of it to be worth reading on a lock screen');

  -- writing to yourself must not notify you
  insert into messages (thread_id, sender_id, body)
  values (v_thread, v_johann, 'Je le rappelle cet après-midi.');
  select count(*) into n from notification_feed
   where kind = 'message_received' and title = 'Johann Lefeuvre';
  perform assert(n = 0, 'and nobody is notified of their own message');

  perform login(v_marie);
  select count(*) into n from notification_feed where kind = 'message_received';
  perform assert(n = 0,
    'someone outside the conversation is not notified of it either');

  -- the apporteur is told there is an invoice waiting on their signature
  perform login(v_johann);
  select count(*) into n from notification_feed
   where kind = 'invoice_ready' and body like 'Facture FA-2026-0003%';
  perform assert(n = 1, 'an issued invoice tells the apporteur to sign it');

  select count(*) into n from notification_feed where read_at is null;
  perform assert(n > 0, 'and they are unread until opened');
  perform assert(unread_notification_count() = n,
    'which is what the badge counts');
  perform mark_notifications_read();
  perform assert(unread_notification_count() = 0, 'opening the list clears it');

  -- device tokens are per person, and re-registering is the normal case
  perform register_device_token('token-johann');
  perform register_device_token('token-johann');
  select count(*) into n from device_tokens;
  perform assert(n = 1, 'registering the same device twice keeps one row');

  perform login(v_marie);
  select count(*) into n from device_tokens;
  perform assert(n = 0, 'and nobody can read anyone else''s device token');
end $$;


\echo ''
\echo '=== 25. Identity is asked for, never inferred ====================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_n      int;
  v_me     profiles%rowtype;
begin
  -- The shape this replaces: read profiles, take the first row, call it "me".
  -- Asserting that it returns the WRONG person would itself depend on
  -- planner order -- which is the whole problem. What is assertable is the
  -- precondition: an admin can see more than one profile, so the first row
  -- is not an identity, whichever row that happens to be.
  perform login(v_pierre);
  select count(*) into v_n from profiles;
  perform assert(v_n > 1,
    'an admin can read more than one profile, so "limit 1" names nobody');

  perform assert(current_profile_id() = v_pierre,
    'while current_profile_id() names exactly one person: the caller');
  select * into v_me from my_profile();
  perform assert(v_me.id = v_pierre and v_me.role = 'admin',
    'and my_profile() returns their own row, not the first one');

  perform login(v_johann);
  perform assert(current_profile_id() = v_johann,
    'an apporteur gets themselves too');
  select * into v_me from my_profile();
  perform assert(v_me.id = v_johann,
    'and their own profile, which is the only one they could see anyway');
end $$;


\echo ''
\echo '=== 26. Issuing an invoice, and correcting one ===================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_stage  text;
  v_inv    invoices%rowtype;
  v_note   invoices%rowtype;
  n int;
begin
  -- a fresh recommendation of Johann's, so this does not ride on earlier state
  perform login(v_johann);
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id,
                               consent_confirmed_at)
  values ('Claire', 'Moreau', v_johann, now()) returning id into v_reco;

  perform login(v_pierre);
  perform assert_denied(v_pierre,
    format('select issue_invoice(%L)', v_reco),
    'a recommendation that has not reached the reward stage cannot be invoiced');

  -- walk it to the reward stage
  for v_stage in select key from stages order by position loop
    perform advance_stage(v_reco, v_stage);
    exit when (select is_reward_trigger from stages where key = v_stage);
  end loop;
  perform assert((select reward_status from recommendations where id = v_reco) = 'earned',
    'reaching the reward stage marks the commission earned');

  perform assert_denied(v_pierre,
    format('select issue_invoice(%L)', v_reco),
    'but with no agreed amount there is nothing to invoice');

  update recommendations set reward_amount = 450 where id = v_reco;

  perform assert_denied(v_johann,
    format('select issue_invoice(%L)', v_reco),
    'an apporteur cannot invoice themselves');

  perform login(v_pierre);
  select * into v_inv from issue_invoice(v_reco);
  perform assert(v_inv.amount_ht = 450,
    'the invoice carries the commission agreed on the recommendation, not a typed figure');
  perform assert(v_inv.number is not null and v_inv.document_sha256 is not null,
    'and is numbered and sealed by the triggers');
  perform assert(v_inv.vat_mode = 'franchise_293b' and v_inv.amount_ttc = 450,
    'with VAT derived from the apporteur, who is not liable');
  perform assert((select reward_status from recommendations where id = v_reco) = 'invoiced',
    'and the recommendation moves on');

  perform assert_denied(v_pierre,
    format('select issue_invoice(%L)', v_reco),
    'a second invoice for the same recommendation is refused');

  -- Marie has no mandate on file: invoicing in her name is unlawful
  perform login(v_marie);
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id,
                               consent_confirmed_at)
  values ('Hugo', 'Blanc', v_marie, now()) returning id into v_reco;
  perform login(v_pierre);
  for v_stage in select key from stages order by position loop
    perform advance_stage(v_reco, v_stage);
    exit when (select is_reward_trigger from stages where key = v_stage);
  end loop;
  update recommendations set reward_amount = 100 where id = v_reco;
  perform assert_denied(v_pierre,
    format('select issue_invoice(%L)', v_reco),
    'an apporteur with no self-billing mandate cannot be invoiced in their name');

  -- ------------------------------------------------------- the credit note
  perform assert_denied(v_pierre,
    format('select create_credit_note(%L, %L)', v_inv.id, 'erreur'),
    'an unsigned invoice needs no credit note: it can still be voided');

  perform login(v_johann);
  perform sign_invoice(v_inv.id, v_inv.document_sha256);
  perform login(v_pierre);
  perform sign_invoice(v_inv.id, v_inv.document_sha256);
  perform assert((select status from invoices where id = v_inv.id) = 'signed',
    'both signatures seal it');

  perform assert_denied(v_johann,
    format('select create_credit_note(%L, %L)', v_inv.id, 'erreur'),
    'an apporteur cannot issue a credit note');
  perform assert_denied(v_pierre,
    format('select create_credit_note(%L, %L)', v_inv.id, '   '),
    'and a credit note must say why it was issued');

  select * into v_note from create_credit_note(v_inv.id, 'Montant erroné');
  perform assert(v_note.amount_ht = -450,
    'the avoir carries the negative amount, cancelling the original');
  perform assert(v_note.number <> v_inv.number and v_note.number is not null,
    'and its own number in the same series, so the series stays continuous');
  perform assert(v_note.prestation_label like 'Avoir sur facture %Montant erroné%',
    'naming the invoice it cancels and why');
  perform assert((select status from invoices where id = v_inv.id) = 'signed',
    'the original is untouched: it is kept, not edited');

  select count(*) into n from payable_invoices where invoice_id = v_inv.id;
  perform assert(n = 0,
    'a credited invoice drops off the payables list, so it is not paid twice');

  perform assert_denied(v_pierre,
    format('select create_credit_note(%L, %L)', v_note.id, 'again'),
    'a credit note cannot itself be credited');
  perform assert_denied(v_pierre,
    format('select create_credit_note(%L, %L)', v_inv.id, 'encore'),
    'nor can one invoice be credited twice');

  perform assert(
    (select reward_status from recommendations
      where id = (select recommendation_id from invoices where id = v_inv.id)) = 'earned',
    'and the commission is owed again, so a corrected invoice can be issued');
end $$;


\echo ''
\echo '=== 27. The commission can actually be set ========================'
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_stage  text;
  v_out    recommendations%rowtype;
begin
  perform login(v_johann);
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id,
                               consent_confirmed_at)
  values ('Lucie', 'Perrin', v_johann, now()) returning id into v_reco;

  perform assert_denied(v_johann,
    format('select set_reward_amount(%L, 500)', v_reco),
    'an apporteur cannot set their own commission');

  perform login(v_pierre);
  perform assert_denied(v_pierre,
    format('select set_reward_amount(%L, 0)', v_reco),
    'nor can it be zero');
  perform assert_denied(v_pierre,
    format('select set_reward_amount(%L, -50)', v_reco),
    'nor negative');

  select * into v_out from set_reward_amount(v_reco, 500);
  perform assert(v_out.reward_amount = 500, 'an admin sets it');
  perform assert(
    (select count(*) from audit_log
      where entity_id = v_reco and action = 'set_reward_amount') = 1,
    'and the change is recorded: it is the number the apporteur is paid');

  -- once invoiced the invoice carries a copy, so changing it would make the
  -- two disagree
  for v_stage in select key from stages order by position loop
    perform advance_stage(v_reco, v_stage);
    exit when (select is_reward_trigger from stages where key = v_stage);
  end loop;
  perform issue_invoice(v_reco);
  perform assert_denied(v_pierre,
    format('select set_reward_amount(%L, 900)', v_reco),
    'but not once the invoice exists: that is what an avoir is for');

  -- signing out must not leave a push token pointed at the last person
  perform login(v_johann);
  perform register_device_token('token-signout');
  perform forget_my_device_tokens();
  perform assert((select count(*) from device_tokens) = 0,
    'signing out forgets this device, so the next person does not get their notifications');
end $$;


\echo ''
\echo '=== 28. Winning a deal keeps the commission ======================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_won    uuid;
  v_lost   uuid;
  v_stage  text;
begin
  -- Only the losing half was covered, and only the losing half was reachable
  -- from the app: every archive it could perform passed won = false, which
  -- cancels an uninvoiced commission. Closing a successful deal took the
  -- money off the apporteur.
  perform login(v_johann);
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id,
                               consent_confirmed_at)
  values ('Sofia', 'Nunes', v_johann, now()) returning id into v_won;
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id,
                               consent_confirmed_at)
  values ('Karim', 'Benali', v_johann, now()) returning id into v_lost;

  perform login(v_pierre);
  for v_stage in select key from stages order by position loop
    perform advance_stage(v_won, v_stage);
    perform advance_stage(v_lost, v_stage);
    exit when (select is_reward_trigger from stages where key = v_stage);
  end loop;

  perform assert((select reward_status from recommendations where id = v_won) = 'earned',
    'both commissions are earned to begin with');

  perform archive_recommendation(v_won, true);
  perform assert((select status from recommendations where id = v_won) = 'archived_won',
    'a won deal is archived as won');
  perform assert((select reward_status from recommendations where id = v_won) = 'earned',
    'and the commission survives it');

  perform archive_recommendation(v_lost, false);
  perform assert((select status from recommendations where id = v_lost) = 'archived_lost',
    'a lost deal is archived as lost');
  perform assert((select reward_status from recommendations where id = v_lost) = 'cancelled',
    'and that one does cancel the commission');
end $$;


\echo ''
\echo '=== 29. What people agree to is shown, and recorded ==============='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_doc    legal_documents%rowtype;
  v_acc    legal_acceptances%rowtype;
  n int;
begin
  -- Nothing ships live: every seeded text still has placeholders in it.
  perform login(v_pierre);
  select count(*) into n from legal_documents where active;
  perform assert(n = 0, 'no legal text is published until someone fills it in');

  perform assert_denied(v_pierre,
    'update legal_documents set active = true where key = ''mandat_facturation''',
    'and a draft still full of [PLACEHOLDERS] cannot be published');

  -- fill it in, the way the client will
  update legal_documents
     set body = regexp_replace(body, '\[[A-ZÉÈÀÇ_ /]{3,}\]', 'Trinity Énergie', 'g')
   where key = 'mandat_facturation';
  update legal_documents
     set body = regexp_replace(replace(body, '[X]', '30'), '\[[^]\n]+\]', 'à compléter', 'g'),
         active = true
   where key = 'mandat_facturation';

  select * into v_doc from legal_documents where key = 'mandat_facturation' and active;
  perform assert(v_doc.sha256 = encode(digest(v_doc.body, 'sha256'), 'hex'),
    'the digest is derived from the text, never supplied by the caller');

  -- an apporteur sees the document itself, not a two-line summary
  perform login(v_johann);
  perform assert(
    (select length(body) from legal_documents_for_me where key = 'mandat_facturation') > 500,
    'the apporteur is shown the whole document');
  perform assert(
    not (select accepted from legal_documents_for_me where key = 'mandat_facturation'),
    'and has not accepted it yet');

  perform assert_denied(v_johann,
    format('select accept_legal_document(%L, %L)', 'mandat_facturation', repeat('f', 64)),
    'accepting a different text than the one published is refused');

  select * into v_acc from accept_legal_document('mandat_facturation', v_doc.sha256);
  perform assert(v_acc.version = v_doc.version and v_acc.sha256 = v_doc.sha256,
    'what is recorded is the version and the exact bytes agreed to');
  perform assert(v_acc.full_name = 'Johann Lefeuvre',
    'under the name of whoever accepted it');
  perform assert(
    (select billing_mandate_signed_at from profiles where id = v_johann) is not null,
    'and the mandate is what unlocks invoicing');
  perform assert(
    (select billing_mandate_version from profiles where id = v_johann) = v_doc.version,
    'with the version kept on the profile, so it is clear which one they signed');
  perform assert((select accepted from legal_documents_for_me
                   where key = 'mandat_facturation'),
    'the app now shows it as accepted');

  -- a revised mandate has to be signed again: that is why it is versioned
  perform login(v_pierre);
  update legal_documents set active = false where key = 'mandat_facturation';
  insert into legal_documents (key, version, title, body, sha256, active)
  select key, '2026-09-2', title, body || E'\n\nArticle 8 — Ajout.', '', true
    from legal_documents where key = 'mandat_facturation' and version = '2026-09-1';

  perform login(v_johann);
  perform assert(
    not (select accepted from legal_documents_for_me where key = 'mandat_facturation'),
    'a revised mandate is unaccepted again, rather than inheriting the old consent');
  perform assert(
    (select count(*) from legal_acceptances where profile_id = v_johann) = 1,
    'and the earlier acceptance is kept: it is the evidence for invoices already issued');

  perform login(v_marie);
  perform assert((select count(*) from legal_acceptances) = 0,
    'nobody can read anyone else''s acceptance');
end $$;


\echo ''
\echo '=== 30. A notification is handed to the push sender ==============='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_thread uuid;
  v_req    net.sent_requests%rowtype;
  n int;
begin
  -- Unconfigured, which is how the project ships: the in-app notification
  -- still lands, and nothing raises.
  perform login(v_johann);
  select start_support_thread() into v_thread;
  perform login(v_pierre);
  insert into messages (thread_id, sender_id, body) values (v_thread, v_pierre, 'Sans push.');
  perform assert((select count(*) from net.sent_requests) = 0,
    'with no push configuration nothing is sent');
  perform login(v_johann);
  perform assert((select count(*) from notification_feed where kind = 'message_received') > 0,
    'but the notification itself still exists, so the app shows it');
end $$;

-- Configured by whoever runs the deploy, not by the app: edge_hooks has no
-- grant for `authenticated` at all, because the secret in it would let its
-- holder push anything to anyone.
reset role;
insert into edge_hooks (name, url, secret)
values ('send-push', 'https://project.supabase.co/functions/v1/send-push', 'shared-secret');
set role authenticated;

do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_thread uuid;
  v_req    net.sent_requests%rowtype;
  n int;
begin
  perform login(v_johann);
  select start_support_thread() into v_thread;
  perform login(v_pierre);
  insert into messages (thread_id, sender_id, body)
  values (v_thread, v_pierre, 'Avec push.');

  select * into v_req from net.sent_requests order by id desc limit 1;
  perform assert(v_req.url = 'https://project.supabase.co/functions/v1/send-push',
    'the notification is posted to the push function');
  perform assert(v_req.headers ->> 'x-hook-secret' = 'shared-secret',
    'with the shared secret, so a stranger who finds the URL cannot send anything');
  perform assert(v_req.body -> 'record' ->> 'profile_id' = v_johann::text,
    'addressed to the person being notified');
  perform assert(v_req.body -> 'record' ->> 'title' = 'Pierre-Louis Tettamanti',
    'carrying the same title the in-app row shows');
  perform assert(v_req.body -> 'record' ->> 'body' = 'Avec push.',
    'and the same body: one renderer, so the lock screen cannot disagree with the list');
  perform assert(v_req.body -> 'record' ->> 'thread_id' = v_thread::text,
    'and the thread id, so a tap can open the conversation');

  -- the secret must not be readable by anyone signed in
  perform login(v_johann);
  perform assert((v_req.body -> 'record' ->> 'badge')::int = unread_notification_count(),
    'and the unread count, so the icon says what the bell will say');
  perform assert_denied(v_johann, 'select secret from edge_hooks',
    'no signed-in user can read the push secret');

end $$;

reset role;
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_before bigint;
  v_ids    uuid[];
begin
  select coalesce(max(id), 0) into v_before from net.sent_requests;
  with n as (
    insert into notifications (profile_id, kind, payload)
    values (v_johann, 'reminder_due', '{"label": "Relancer"}')
    returning id
  ) select array_agg(id) into v_ids from n;
  perform assert(not exists (select 1 from net.sent_requests
                              where id > v_before and url like '%/send-push'),
    'a reminder is not pushed: the phone that set it already rang, at the minute');
  delete from notifications where id = any (v_ids);
end $$;
update edge_hooks set enabled = false where name = 'send-push';
set role authenticated;

do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_thread uuid;
  n int;
begin
  perform login(v_johann);
  select start_support_thread() into v_thread;
  perform login(v_pierre);
  select count(*) into n from net.sent_requests;
  insert into messages (thread_id, sender_id, body) values (v_thread, v_pierre, 'Coupé.');
  perform assert((select count(*) from net.sent_requests) = n,
    'disabling it stops the push, and only the push');
end $$;


\echo ''
\echo '=== 31. The mandate cannot be granted by writing a column ========='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
begin
  -- The old client did exactly this: PATCH profiles, set the timestamp, done.
  -- It never showed the document, and RLS let it through because a person may
  -- edit their own row.
  perform assert_denied(v_johann,
    format('update profiles set billing_mandate_signed_at = now() where id = %L', v_johann),
    'an apporteur cannot grant themselves a mandate by writing the column');
  perform assert_denied(v_pierre,
    format('update profiles set billing_mandate_signed_at = now() where id = %L', v_johann),
    'and neither can an admin: the mandate is the apporteur''s to give');
  perform assert_denied(v_johann,
    format('update profiles set billing_mandate_version = ''forged'' where id = %L', v_johann),
    'nor forge which version was signed');

  -- the ordinary parts of the profile are still editable
  perform login(v_johann);
  update profiles set city = 'Roubaix' where id = v_johann;
  perform assert((select city from profiles where id = v_johann) = 'Roubaix',
    'while the rest of the profile stays editable');
end $$;


-- ------------------------------------------------- fixtures for 32 onwards
-- Eva is a second apporteur with a mandate, so the money sections below run
-- on their own documents instead of riding on Johann's history. The other
-- account has signed up and has no profile: it is what anybody holds the
-- moment sign-up is open.
reset role;
insert into auth.users (id, email) values
  ('66666666-6666-6666-6666-666666666666', 'intrus@example.test'),
  ('77777777-7777-7777-7777-777777777777', 'eva@example.test');
insert into profiles (id, role, status, first_name, last_name, email, city,
                      company_name, billing_mandate_signed_at, address, postal_code)
values ('77777777-7777-7777-7777-777777777777', 'apporteur', 'active', 'Eva', 'Garnier',
        'eva@example.test', 'Arras', 'Garnier Conseil', timestamptz '2026-01-05 10:00',
        '8 rue Gambetta', '62000');

-- A recommendation of p_parrain's, walked by p_admin to the reward stage with
-- an agreed commission. Leaves the admin logged in.
create or replace function test_reco_at_reward(
  p_parrain uuid, p_admin uuid, p_amount numeric, p_name text)
returns uuid language plpgsql as $$
declare
  v_reco  uuid;
  v_stage text;
begin
  perform login(p_parrain);
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id,
                               consent_confirmed_at)
  values (p_name, 'Test', p_parrain, now())
  returning id into v_reco;

  perform login(p_admin);
  for v_stage in select key from stages order by position loop
    perform advance_stage(v_reco, v_stage);
    exit when (select is_reward_trigger from stages where key = v_stage);
  end loop;
  perform set_reward_amount(v_reco, p_amount);
  return v_reco;
end $$;

-- Issues the invoice for p_reco and has both parties sign it.
create or replace function test_sealed_invoice(p_reco uuid, p_admin uuid)
returns invoices language plpgsql as $$
declare v_inv invoices%rowtype;
begin
  perform login(p_admin);
  select * into v_inv from issue_invoice(p_reco);
  perform login(v_inv.apporteur_id);
  perform sign_invoice(v_inv.id, v_inv.document_sha256);
  perform login(p_admin);
  perform sign_invoice(v_inv.id, v_inv.document_sha256);
  select * into v_inv from invoices where id = v_inv.id;
  return v_inv;
end $$;
set role authenticated;

\echo ''
\echo '=== 32. Nobody can make themselves an administrator ==============='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_ghost  uuid := '66666666-6666-6666-6666-666666666666';
begin
  -- Sign-up is open in config.toml, so anyone can hold an account with no
  -- profile. The invitation is supposed to be the only way to get one.
  perform assert_denied(v_ghost, format(
    'insert into profiles (id, role, status, first_name, last_name, email)
     values (%L, ''admin'', ''active'', ''Intrus'', ''Admin'', ''intrus@example.test'')',
    v_ghost),
    'a fresh sign-up cannot write itself an admin profile');
  perform assert_denied(v_ghost, format(
    'insert into profiles (id, first_name, last_name, email)
     values (%L, ''Intrus'', ''Apporteur'', ''intrus@example.test'')', v_ghost),
    'nor any profile at all: a profile comes from an invitation');
  perform login(v_ghost);
  perform assert(my_account_state() ->> 'state' = 'needs_invite',
    'so it is still asked for an invitation');

  perform assert_denied(v_johann,
    format('update profiles set role = ''admin'' where id = %L', v_johann),
    'an apporteur cannot promote themselves');
  perform assert_denied(v_johann,
    format('update profiles set role = ''manager'' where id = %L', v_johann),
    'nor make themselves a manager');
  perform login(v_pierre);
  perform set_member_status('55555555-5555-5555-5555-555555555555', 'suspended');
  perform assert_denied('55555555-5555-5555-5555-555555555555',
    'update profiles set status = ''active''
      where id = ''55555555-5555-5555-5555-555555555555''',
    'a suspended member cannot reinstate themselves');
  perform login(v_pierre);
  perform set_member_status('55555555-5555-5555-5555-555555555555', 'active');
  perform assert_denied(v_johann,
    format('update profiles set vat_liable = true, vat_number = ''FR1'' where id = %L', v_johann),
    'nor switch on VAT, which adds 20 % to what the company pays them');
  perform assert_denied(v_marie,
    format('update profiles set bank_details_on_file = true where id = %L', v_marie),
    'nor declare themselves payable');
  perform assert_denied(v_johann,
    format('update profiles set kyc_state = ''approved'' where id = %L', v_johann),
    'nor approve their own identity check');
  perform assert_denied(v_johann,
    format('update profiles set email = ''autre@example.test'' where id = %L', v_johann),
    'nor change the address their invitation was checked against');
  perform assert_denied(v_johann,
    format('update profiles set first_name = ''X'' where id = %L', v_marie),
    'nor touch anybody else''s profile');

  perform login(v_johann);
  update profiles
     set phone = '+33 6 00 00 00 01', company_name = 'Lefeuvre Conseil SARL',
         siret = '12345678900011'
   where id = v_johann;
  perform assert(found, 'the details an apporteur owns stay theirs to edit');
  perform assert(not is_admin(v_johann), 'and Johann is still an apporteur');

  perform login(v_pierre);
  update profiles set vat_liable = true, vat_number = 'FR00123456789' where id = v_johann;
  perform assert((select vat_liable from profiles where id = v_johann),
    'an admin still records a member''s VAT status');
  update profiles set vat_liable = false, vat_number = null where id = v_johann;
end $$;

\echo ''
\echo '=== 33. A new lead starts at the beginning, whatever the app sends ='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_first  uuid;
  v_last   uuid;
  v_row    recommendations%rowtype;
begin
  select id into v_first from stages order by position limit 1;
  select id into v_last  from stages order by position desc limit 1;

  -- The update guard stopped all of this on an existing row. On a new row
  -- nothing did, so an apporteur could file a lead already at the last stage,
  -- with their own commission on it, marked earned.
  perform login(v_johann);
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id,
                               consent_confirmed_at, current_stage_id, reward_amount,
                               reward_status, status, assigned_admin_id, created_at)
  values ('Paul', 'Faure', v_johann, timestamptz '2000-01-01', v_last, 99999,
          'earned', 'archived_won', v_pierre, timestamptz '2020-01-01')
  returning * into v_row;

  perform assert(v_row.current_stage_id = v_first,
    'a lead filed with a later stage still starts at the first one');
  perform assert(v_row.reward_amount is null,
    'an apporteur cannot name their own commission');
  perform assert(v_row.reward_status = 'pending',
    'nor declare it earned');
  perform assert(v_row.status = 'active' and v_row.archived_at is null,
    'nor file it already closed');
  perform assert(v_row.assigned_admin_id is null,
    'nor choose who handles it');
  perform assert(v_row.created_at = now(),
    'nor backdate it, which decides who holds a disputed lead');
  perform assert(v_row.consent_confirmed_at = now(),
    'and consent is stamped with the server''s time, not the one sent');

  perform assert_denied(v_johann, format(
    'insert into recommendations (filleul_first_name, filleul_last_name, parrain_id)
     values (''Sans'', ''Consentement'', %L)', v_johann),
    'a lead cannot be filed without the filleul''s consent');
  perform assert_denied(v_johann, format(
    'insert into recommendations (filleul_first_name, filleul_last_name, parrain_id,
                                  consent_confirmed_at)
     values (''Au nom'', ''De Marie'', %L, now())', v_marie),
    'nor in someone else''s name');
  perform assert_denied(v_pierre,
    format('select issue_invoice(%L)', v_row.id),
    'so nothing about a new lead can be invoiced');
end $$;

\echo ''
\echo '=== 34. Internal functions cannot be called from outside =========='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_before int;
  n int;
begin
  perform login(v_pierre);
  select last_index into v_before from invoice_sequences where year = 2026;

  perform assert_denied(v_johann, 'select next_invoice_index(2026)',
    'an apporteur cannot take an invoice number');
  perform assert_denied(v_pierre, 'select next_invoice_index(2026)',
    'nor can an admin, other than by issuing an invoice');
  perform assert_denied(v_pierre, 'update invoice_sequences set last_index = 0',
    'and the counter cannot be rewound by hand');

  perform login(v_pierre);
  perform assert((select last_index from invoice_sequences where year = 2026) = v_before,
    'so the series has no hole in it');

  perform assert(not has_function_privilege('anon', 'public.next_invoice_index(int)', 'execute'),
    'somebody with no account cannot reach it either');
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  perform assert(n = 0, 'nor any other function: nothing runs without signing in');
  perform assert(
    has_function_privilege('authenticated', 'public.issue_invoice(uuid,text)', 'execute'),
    'while the ones the app calls still work');
end $$;

\echo ''
\echo '=== 35. Apporteurs talk to the company, not to each other ========='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_thread uuid;
begin
  perform assert_denied(v_johann,
    format('select start_direct_thread(%L)', v_marie),
    'an apporteur cannot open a conversation with another apporteur');

  -- nor by writing the rows start_direct_thread would have written
  perform login(v_johann);
  insert into threads (kind, created_by) values ('direct', v_johann) returning id into v_thread;
  perform assert_denied(v_johann, format(
    'insert into thread_participants (thread_id, profile_id) values (%L, %L)',
    v_thread, v_marie),
    'nor by adding them to a thread by hand');

  perform login(v_johann);
  perform assert(chat_display_name(v_marie) is null,
    'so another apporteur''s name stays out of reach');

  perform login(v_pierre);
  select start_direct_thread(v_marie) into v_thread;
  perform assert(v_thread is not null, 'while the company can write to any member');
end $$;

\echo ''
\echo '=== 36. The duplicate check is not a directory ===================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_newbie uuid := '44444444-4444-4444-4444-444444444444';
  v_ghost  uuid := '66666666-6666-6666-6666-666666666666';
  i int;
begin
  perform assert_denied(v_ghost, 'select check_duplicate_filleul(''0611223344'')',
    'an account without a membership cannot look up who is a lead');

  -- one honest form checks a handful of numbers; a script checks thousands
  perform login(v_newbie);
  for i in 1..120 loop
    perform check_duplicate_filleul('06' || lpad(i::text, 8, '0'));
  end loop;
  perform assert_denied(v_newbie, 'select check_duplicate_filleul(''0699999999'')',
    'and a member checking numbers by the hundred is stopped');

  perform login(v_johann);
  perform assert(check_duplicate_filleul('0699999999') ? 'held_by_someone_else',
    'without slowing anyone else down');
end $$;

\echo ''
\echo '=== 37. Only an invoice waiting for signatures can be signed ======'
do $$
declare
  v_eva    uuid := '77777777-7777-7777-7777-777777777777';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_inv    invoices%rowtype;
  v_sealed invoices%rowtype;
begin
  v_reco := test_reco_at_reward(v_eva, v_pierre, 200, 'Signature');
  select * into v_inv from issue_invoice(v_reco);

  perform assert_denied(v_pierre,
    format('update invoices set amount_ht = 9999 where id = %L', v_inv.id),
    'an issued invoice cannot be edited, even before anybody has signed it');
  perform assert_denied(v_pierre,
    format('update invoices set status = ''signed'' where id = %L', v_inv.id),
    'nor declared signed without its two signatures');
  perform assert_denied(v_pierre,
    format('update invoices set status = ''paid'' where id = %L', v_inv.id),
    'nor declared paid before anybody agreed to it');

  perform assert_denied(v_eva, format(
    'insert into invoice_signatures (invoice_id, signer_id, signer_role, signer_full_name,
                                     document_sha256)
     values (%L, %L, ''apporteur'', ''Eva Garnier'', %L)', v_inv.id, v_eva, repeat('d', 64)),
    'a signature written straight into the table must still bind to the issued document');
  perform login(v_eva);
  insert into invoice_signatures (invoice_id, signer_id, signer_role, signer_full_name,
                                  document_sha256)
  values (v_inv.id, v_eva, 'apporteur', 'Quelqu''un d''autre', v_inv.document_sha256);
  perform assert(
    (select signer_full_name from invoice_signatures
      where invoice_id = v_inv.id and signer_role = 'apporteur') = 'Eva Garnier',
    'and carries the signer''s own name, not one the client typed');

  perform login(v_pierre);
  update invoices set status = 'void' where id = v_inv.id;
  perform assert(found, 'an invoice the company has not signed can still be voided');
  perform assert_denied(v_pierre,
    format('select sign_invoice(%L, %L)', v_inv.id, v_inv.document_sha256),
    'after which it can no longer be signed');
  perform assert((select reward_status from recommendations where id = v_reco) = 'earned',
    'and the commission is waiting to be invoiced again');

  select * into v_sealed from test_sealed_invoice(v_reco, v_pierre);
  perform assert(v_sealed.status = 'signed', 'which it then is');
  perform assert_denied(v_pierre,
    format('update invoices set status = ''void'' where id = %L', v_sealed.id),
    'a signed invoice cannot be voided: only a credit note cancels it');
  perform assert_denied(v_eva,
    format('select sign_invoice(%L, %L)', v_sealed.id, v_sealed.document_sha256),
    'and signing it again is refused');
end $$;

\echo ''
\echo '=== 38. Each invoice is paid once, to someone who can be paid ====='
do $$
declare
  v_eva    uuid := '77777777-7777-7777-7777-777777777777';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_a      invoices%rowtype;
  v_b      invoices%rowtype;
  v_note   invoices%rowtype;
  v_fix    invoices%rowtype;
  v_batch  payout_batches%rowtype;
begin
  v_reco := test_reco_at_reward(v_eva, v_pierre, 300, 'Paiement');
  select * into v_a from test_sealed_invoice(v_reco, v_pierre);

  perform assert_denied(v_pierre,
    format('select create_payout_batch(array[%L]::uuid[])', v_a.id),
    'nobody is paid before the company has their payment details on file');

  perform login(v_pierre);
  perform set_bank_details_on_file(v_eva, true, 'COMPTA-0007');
  select * into v_batch from create_payout_batch(array[v_a.id], 'VIR-1');
  perform assert(v_batch.total = 300, 'once it has, the invoice is paid');
  perform assert_denied(v_pierre,
    format('select create_payout_batch(array[%L]::uuid[])', v_a.id),
    'and paying the same invoice a second time is refused');
  perform assert((select count(*) from commissions where invoice_id = v_a.id) = 1,
    'so it is recorded as paid exactly once');

  perform login(v_eva);
  perform assert(exists (
      select 1 from notification_feed
       where kind = 'payment_sent' and title = 'Paiement envoyé'
         and body = '300,00 € en route'),
    'the apporteur is told in words, not a blank row, that the money is coming');

  -- credited before it was paid: there is nothing to pay
  v_reco := test_reco_at_reward(v_eva, v_pierre, 120, 'Annulee');
  select * into v_b from test_sealed_invoice(v_reco, v_pierre);
  perform create_credit_note(v_b.id, 'Doublon');
  perform assert_denied(v_pierre,
    format('select create_payout_batch(array[%L]::uuid[])', v_b.id),
    'an invoice that has been credited cannot be paid');

  -- credited after it was paid: the credit note is money owed back
  select * into v_note from create_credit_note(v_a.id, 'Montant erroné');
  perform login(v_eva);
  perform sign_invoice(v_note.id, v_note.document_sha256);
  perform login(v_pierre);
  perform sign_invoice(v_note.id, v_note.document_sha256);
  perform assert((select count(*) from payable_invoices where invoice_id = v_note.id) = 1,
    'a credit note on a paid invoice waits on the payables list, as money owed back');
  perform assert_denied(v_pierre,
    format('select create_payout_batch(array[%L]::uuid[])', v_note.id),
    'it cannot be settled on its own: a negative transfer is not a payment');

  perform set_reward_amount(v_a.recommendation_id, 350);
  select * into v_fix from test_sealed_invoice(v_a.recommendation_id, v_pierre);
  select * into v_batch from create_payout_batch(array[v_fix.id, v_note.id], 'VIR-2');
  perform assert(v_batch.total = 50,
    'set against the corrected invoice, only the difference is paid');
end $$;

\echo ''
\echo '=== 39. A credited invoice can be reissued, on the original terms ='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_inv    invoices%rowtype;
  v_note   invoices%rowtype;
  v_fix    invoices%rowtype;
begin
  v_reco := test_reco_at_reward(v_johann, v_pierre, 400, 'Correction');
  select * into v_inv from test_sealed_invoice(v_reco, v_pierre);

  -- Johann's VAT status changes between the invoice and its correction
  update profiles set vat_liable = true, vat_number = 'FR11111111111' where id = v_johann;

  select * into v_note from create_credit_note(v_inv.id, 'Erreur de prestation');
  perform assert(v_note.vat_rate = v_inv.vat_rate and v_note.amount_ttc = -v_inv.amount_ttc,
    'a credit note reverses the original exactly, at the original''s VAT rate');

  perform login(v_johann);
  perform sign_invoice(v_note.id, v_note.document_sha256);
  perform login(v_pierre);
  perform sign_invoice(v_note.id, v_note.document_sha256);
  perform assert((select reward_status from recommendations where id = v_reco) = 'earned',
    'signing the credit note leaves the commission owed, instead of marking it invoiced');

  select * into v_fix from issue_invoice(v_reco);
  perform assert(v_fix.id is not null and v_fix.vat_rate = 20,
    'and the corrected invoice can be issued, on the apporteur''s current terms');
  perform assert(
    (select count(*) from commission_statement where recommendation_id = v_reco) = 1,
    'the statement lists the commission once, not once per document');
  perform assert((select invoice_id from recommendation_feed where id = v_reco) = v_fix.id,
    'and the card opens the corrected invoice, not the credit note');

  update profiles set vat_liable = false, vat_number = null where id = v_johann;
end $$;

\echo ''
\echo '=== 40. An invoice keeps the parties as they were when issued ====='
do $$
declare
  v_johann  uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre  uuid := '33333333-3333-3333-3333-333333333333';
  v_reco    uuid;
  v_inv     invoices%rowtype;
  v_company text;
begin
  v_reco := test_reco_at_reward(v_johann, v_pierre, 250, 'Instantane');
  select * into v_inv from issue_invoice(v_reco);

  perform login(v_johann);
  select company_name into v_company from profiles where id = v_johann;
  update profiles set company_name = 'Nouvelle Raison Sociale' where id = v_johann;

  perform assert(invoice_document(v_inv.id) -> 'apporteur' ->> 'company' = v_company,
    'renaming the company afterwards does not rewrite an issued invoice');
  perform assert(
    encode(digest(invoice_canonical_text(v_inv.id), 'sha256'), 'hex') = v_inv.document_sha256,
    'so what was signed can still be reproduced byte for byte');

  update profiles set company_name = v_company where id = v_johann;
end $$;

\echo ''
\echo '=== 41. The pipeline only moves forward, and only while open ======'
do $$
declare
  v_eva    uuid := '77777777-7777-7777-7777-777777777777';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_n      int;
  v_rate   numeric;
begin
  v_reco := test_reco_at_reward(v_eva, v_pierre, 100, 'Pipeline');

  perform assert_denied(v_pierre,
    format('select advance_stage(%L, ''a_contacter'')', v_reco),
    'the pipeline does not move backwards: that is what "Remettre à zéro" is for');

  perform login(v_pierre);
  select count(*) into v_n from recommendation_stage_events where recommendation_id = v_reco;
  perform advance_stage(v_reco, 'devis_signe');
  perform assert(
    (select count(*) from recommendation_stage_events where recommendation_id = v_reco) = v_n,
    'validating the current stage twice changes nothing');

  perform archive_recommendation(v_reco, false);
  perform assert_denied(v_pierre,
    format('select advance_stage(%L, ''mission_terminee'')', v_reco),
    'a closed lead cannot be advanced');

  -- that lead was lost, so it is not a conversion
  perform login(v_eva);
  select round(100.0 * count(*) filter (where reward_status in ('earned','invoiced','paid'))
               / count(*), 1)
    into v_rate
    from recommendations;
  perform assert((dashboard_stats() ->> 'conversion_rate')::numeric = v_rate
                 and v_rate < 100,
    'and a lost lead does not count as a conversion on the dashboard');
end $$;

\echo ''
\echo '=== 42. A legal text with any blank left in it is not published ==='
do $$
declare
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
begin
  -- what the old check let through: lowercase blanks, short ones, notes
  perform login(v_pierre);
  update legal_documents
     set body = regexp_replace(body, '\[[A-ZÉÈÀÇ_ /]{3,}\]', 'Trinity Énergie', 'g')
   where key = 'cgu';
  perform assert_denied(v_pierre,
    'update legal_documents set active = true where key = ''cgu''',
    'blanks such as [adresse] or [X] still stop the CGU going live');
  perform assert_denied(v_pierre,
    $q$insert into legal_documents (key, version, title, body, sha256, active)
       values ('essai', '1', 'Essai', 'Délai : [À VALIDER : délai]', '', true)$q$,
    'and so does a note left for the lawyer');

  perform login(v_pierre);
  insert into legal_documents (key, version, title, body, sha256, active)
  values ('essai', '2', 'Essai', 'Voir [la page](https://example.test).', '', true);
  perform assert(found, 'while a link written as [text](url) is not taken for a blank');
  delete from legal_documents where key = 'essai';
end $$;

\echo ''
\echo '=== 43. Deleting an account removes the person, not the invoices =='
do $$
declare
  v_eva    uuid := '77777777-7777-7777-7777-777777777777';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_inv    uuid;
  v_n      int;
  v_prof   profiles%rowtype;
begin
  perform assert_denied(v_pierre, 'select request_account_deletion()',
    'the last administrator cannot delete their account and lock the company out');

  perform login(v_eva);
  select id into v_inv from invoices where apporteur_id = v_eva order by created_at limit 1;
  select count(*) into v_n from invoices where apporteur_id = v_eva;
  perform register_device_token('token-eva');
  perform request_account_deletion();
  perform assert(my_account_state() ->> 'state' = 'suspended',
    'the account is closed at once');

  perform login(v_pierre);
  select * into v_prof from profiles where id = v_eva;
  perform assert(v_prof.first_name = 'Compte' and v_prof.last_name = 'supprimé'
                 and v_prof.email like 'deleted+%@invalid'
                 and v_prof.phone is null and v_prof.company_name is null
                 and v_prof.city is null and not v_prof.bank_details_on_file,
    'and the person''s details are erased from it');
  perform assert((select count(*) from invoices where apporteur_id = v_eva) = v_n,
    'while every invoice issued in their name is kept, as the law requires');
  perform assert(invoice_document(v_inv) -> 'apporteur' ->> 'name' = 'Eva Garnier',
    'under the name it was issued to');
end $$;

reset role;
do $$
begin
  perform assert(
    not exists (select 1 from auth.users where id = '77777777-7777-7777-7777-777777777777'),
    'the login itself is deleted, so the address can no longer sign in');
  perform assert(
    not exists (select 1 from device_tokens
                 where profile_id = '77777777-7777-7777-7777-777777777777'),
    'and no device keeps receiving their notifications');
end $$;

set role authenticated;

\echo ''
\echo '=== 44. An invoice carries what the law requires of it ============'
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_inv    invoices%rowtype;
  v_note   invoices%rowtype;
  v_doc    jsonb;
  v_text   text;
begin
  perform login(v_johann);
  update profiles set address = '12 rue des Lilas', postal_code = '59000'
   where id = v_johann;

  v_reco := test_reco_at_reward(v_johann, v_pierre, 600, 'Mentions');
  select * into v_inv from issue_invoice(v_reco);
  v_doc  := invoice_document(v_inv.id);
  v_text := invoice_canonical_text(v_inv.id);

  perform assert(v_doc ->> 'kind' = 'invoice', 'an invoice says it is one');
  perform assert(v_doc ->> 'self_billing_mention' like 'Autofacturation%',
    'and that the customer drew it up in the supplier''s name');
  perform assert(v_doc -> 'customer' ->> 'legal_name' = 'Trinity Énergie'
                 and v_doc -> 'customer' ->> 'siren' = '123456789'
                 and v_doc -> 'customer' ->> 'address' = '1 rue de la Gare',
    'the customer is the company, by its legal identity, not the admin who clicked');
  perform assert(v_doc -> 'apporteur' ->> 'address' = '12 rue des Lilas',
    'the supplier''s address is on it');
  perform assert(v_inv.due_on = v_inv.issued_on + 30,
    'payment is due thirty days after issue unless the company says otherwise');
  perform assert(v_doc ->> 'late_payment_mention' like '%trois fois le taux d''intérêt légal%'
                 and v_doc ->> 'late_payment_mention' like '%40 €%',
    'with the late-payment rate and the 40 € recovery fee spelled out');
  perform assert(v_text like '%Autofacturation%' and v_text like '%123456789%',
    'and all of it is part of what both parties sign');

  -- the company's details changing later does not rewrite an issued invoice
  perform login(v_pierre);
  update billing_settings set address = '99 avenue Ailleurs';
  perform assert(invoice_document(v_inv.id) -> 'customer' ->> 'address' = '1 rue de la Gare',
    'moving offices does not move the address on invoices already issued');
  update billing_settings set address = '1 rue de la Gare';

  -- a credit note says what it is and what it cancels
  perform login(v_johann);
  perform sign_invoice(v_inv.id, v_inv.document_sha256);
  perform login(v_pierre);
  perform sign_invoice(v_inv.id, v_inv.document_sha256);
  select * into v_note from create_credit_note(v_inv.id, 'Erreur');
  v_doc := invoice_document(v_note.id);
  perform assert(v_doc ->> 'kind' = 'credit_note' and v_doc ->> 'corrects_number' = v_inv.number,
    'a credit note is titled as one and names the invoice it cancels');


  perform assert_denied(v_johann, 'update billing_settings set siren = ''000000000''',
    'only the company edits its own identity');
end $$;

reset role;
do $$
begin
  -- what happens on a project where nobody filled the company in. There has
  -- to be something invoiceable, or the refusal below would prove nothing.
  perform assert(exists (select 1 from recommendations r
                          where reward_status = 'earned' and reward_amount > 0
                            and not has_live_invoice(r.id)),
    'a commission is waiting to be invoiced');
  delete from billing_settings;
  perform assert_denied('33333333-3333-3333-3333-333333333333',
    'select issue_invoice(id) from recommendations r
      where reward_status = ''earned'' and reward_amount > 0
        and not has_live_invoice(r.id) limit 1',
    'no invoice can be issued before the company''s identity is set up');
  insert into billing_settings (legal_name, siren, address, postal_code, city)
  values ('Trinity Énergie', '123456789', '1 rue de la Gare', '59310', 'Aix-en-Pévèle');
end $$;
set role authenticated;

\echo ''
\echo '=== 45. A signature records where it came from, not what it claims '
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_inv    invoices%rowtype;
  v_sig    invoice_signatures%rowtype;
begin
  v_reco := test_reco_at_reward(v_johann, v_pierre, 80, 'Preuve');
  select * into v_inv from issue_invoice(v_reco);

  -- what PostgREST passes the database for a request from the phone
  perform set_config('request.headers',
    '{"x-forwarded-for": "203.0.113.7, 10.0.0.1", "user-agent": "TrinityEnergie/1 CFNetwork"}',
    true);
  perform login(v_johann);
  select * into v_sig from sign_invoice(v_inv.id, v_inv.document_sha256,
                                        '1.2.3.4'::inet, 'forged agent');
  perform assert(v_sig.ip_address = '203.0.113.7'::inet,
    'the address kept is the one the request came from, not the one the app sent');
  perform assert(v_sig.user_agent = 'TrinityEnergie/1 CFNetwork',
    'and so is the user agent');
  perform set_config('request.headers', '', true);
end $$;

reset role;
-- the invoice-pdf function, as deployed
insert into edge_hooks (name, url, secret)
values ('invoice-pdf', 'https://project.supabase.co/functions/v1/invoice-pdf', 'pdf-secret');
set role authenticated;

\echo ''
\echo '=== 46. Sealing an invoice asks the server to keep its PDF ========'
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_inv    invoices%rowtype;
  v_before bigint;
  v_req    net.sent_requests%rowtype;
begin
  v_reco := test_reco_at_reward(v_johann, v_pierre, 90, 'Retention');
  select * into v_inv from issue_invoice(v_reco);
  select coalesce(max(id), 0) into v_before from net.sent_requests;

  perform login(v_johann);
  perform sign_invoice(v_inv.id, v_inv.document_sha256);
  perform assert(not exists (select 1 from net.sent_requests
                              where id > v_before and body ->> 'invoice_id' = v_inv.id::text),
    'one signature does not ask for the document yet');

  perform login(v_pierre);
  perform sign_invoice(v_inv.id, v_inv.document_sha256);
  select * into v_req from net.sent_requests
   where id > v_before and body ->> 'invoice_id' = v_inv.id::text;
  perform assert(v_req.url = 'https://project.supabase.co/functions/v1/invoice-pdf',
    'the second seals it, and the server is asked to render and keep the PDF at once');
  perform assert(v_req.headers ->> 'x-hook-secret' = 'pdf-secret',
    'with the shared secret, so a stranger who finds the URL cannot trigger it');

  perform assert_denied(v_pierre, 'select secret from edge_hooks',
    'and no signed-in user can read that secret');
end $$;

reset role;
set role service_role;
do $$
declare v_n int;
begin
  -- whatever the trigger's call missed, the sweep asks for again
  perform assert(exists (select 1 from invoices_missing_pdf(100)),
    'a sealed invoice without its PDF is on the sweep''s list');
  select request_missing_invoice_pdfs() into v_n;
  perform assert(v_n > 0, 'and the sweep asks the server for it again');
  perform assert(
    (invoice_mail_recipients((select id from invoices where number = 'FA-2026-0001')) ->> 'apporteur_email')
      = 'johann@example.test',
    'the signed PDF is addressed to the apporteur');
end $$;

set role authenticated;

\echo ''
\echo '=== 47. A lead''s documents are seen by whoever sees the lead ======'
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_path   text;
  v_doc    documents%rowtype;
begin
  perform login(v_johann);
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id,
                               consent_confirmed_at)
  values ('Facture', 'Energie', v_johann, now()) returning id into v_reco;
  v_path := v_reco || '/' || gen_random_uuid() || '.pdf';

  perform assert_denied(v_marie, format(
    'insert into storage.objects (bucket_id, name, owner) values (''documents'', %L, %L)',
    v_path, v_marie),
    'another apporteur cannot put a file in Johann''s lead');
  perform assert_denied(v_johann, format(
    'insert into storage.objects (bucket_id, name, owner) values (''documents'', %L, %L)',
    v_reco || '/../../invoices/x.pdf', v_johann),
    'nor can a name escape the lead it is filed under');

  perform login(v_johann);
  insert into storage.objects (bucket_id, name, owner) values ('documents', v_path, v_johann);

  perform assert_denied(v_johann, format(
    'select register_document(%L, %L, ''facture.pdf'', 120000, ''application/pdf'', ''contract'')',
    v_reco, v_path),
    'an apporteur files a bill, not a contract: those are the company''s');
  perform assert_denied(v_johann, format(
    'select register_document(%L, %L, ''facture.exe'', 120000, ''application/x-msdownload'')',
    v_reco, v_path),
    'only PDFs and photos are accepted');
  perform assert_denied(v_johann, format(
    'select register_document(%L, %L, ''facture.pdf'', 50000000, ''application/pdf'')',
    v_reco, v_path),
    'and nothing over 10 MB');
  perform assert_denied(v_johann, format(
    'select register_document(%L, %L, ''x.pdf'', 1000, ''application/pdf'')',
    v_reco, v_reco || '/' || gen_random_uuid() || '.pdf'),
    'a file that was never uploaded cannot be listed');

  perform login(v_johann);
  select * into v_doc from register_document(v_reco, v_path, '  ../Facture EDF mars.pdf ',
                                             120000, 'application/pdf');
  perform assert(v_doc.kind = 'energy_bill' and v_doc.uploaded_by = v_johann,
    'Johann attaches the filleul''s energy bill to his lead');
  perform assert(v_doc.filename = '..-Facture EDF mars.pdf',
    'under a display name that can never be taken for a path');

  perform login(v_marie);
  perform assert((select count(*) from documents where recommendation_id = v_reco) = 0,
    'another apporteur does not see it listed');
  perform assert((select count(*) from storage.objects where name = v_path) = 0,
    'nor can read the file');

  perform login(v_pierre);
  perform assert((select count(*) from storage.objects where name = v_path) = 1,
    'the company reads it');
  perform assert_denied(v_marie, format('select remove_document(%L)', v_doc.id),
    'and only the person who added it, or the company, can take it back');

  perform login(v_johann);
  perform assert(remove_document(v_doc.id) = v_path,
    'Johann can take back what he added today');
end $$;

reset role;
-- a second admin, to see who is told what
insert into auth.users (id, email) values ('88888888-8888-8888-8888-888888888888', 'claire@trinity-energie.test');
insert into profiles (id, role, status, first_name, last_name, email)
values ('88888888-8888-8888-8888-888888888888', 'admin', 'active', 'Claire', 'Admin',
        'claire@trinity-energie.test');
insert into edge_hooks (name, url, secret)
values ('notify-email', 'https://project.supabase.co/functions/v1/notify-email', 'mail-secret');
set role authenticated;

\echo ''
\echo '=== 48. The company hears about what needs it ====================='
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_claire uuid := '88888888-8888-8888-8888-888888888888';
  v_reco   uuid;
  v_inv    invoices%rowtype;
  v_req    net.sent_requests%rowtype;
  v_before bigint;
begin
  select coalesce(max(id), 0) into v_before from net.sent_requests;
  perform login(v_johann);
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id, consent_confirmed_at)
  values ('Alerte', 'Admin', v_johann, now()) returning id into v_reco;

  perform login(v_pierre);
  perform assert(exists (select 1 from notification_feed
                          where kind = 'lead_created' and recommendation_id = v_reco
                            and body like 'Alerte Admin, recommandé par Johann%'),
    'a new lead is announced to the company, with who sent it');
  perform login(v_claire);
  perform assert(exists (select 1 from notifications
                          where kind = 'lead_created' and payload ->> 'recommendation_id' = v_reco::text),
    'to every admin while nobody follows it yet');
  perform login(v_johann);
  perform assert(not exists (select 1 from notifications
                              where kind = 'lead_created' and payload ->> 'recommendation_id' = v_reco::text),
    'and not to the apporteur who sent it');

  select * into v_req from net.sent_requests
   where id > v_before and url like '%notify-email' order by id limit 1;
  perform assert(v_req.headers ->> 'x-hook-secret' = 'mail-secret',
    'it goes out by email as well as push');

  -- once someone follows the lead, only they are told
  perform login(v_pierre);
  perform reassign_recommendation(v_reco, v_pierre);
  perform test_reco_at_reward(v_johann, v_pierre, 70, 'Suivi');
  update recommendations set assigned_admin_id = v_pierre
   where filleul_first_name = 'Suivi' and parrain_id = v_johann;
  select * into v_inv from issue_invoice(
    (select id from recommendations where filleul_first_name = 'Suivi' and parrain_id = v_johann));
  perform login(v_johann);
  perform sign_invoice(v_inv.id, v_inv.document_sha256);
  perform login(v_pierre);
  perform assert(exists (select 1 from notification_feed
                          where kind = 'invoice_signed_by_apporteur' and invoice_id = v_inv.id),
    'the admin following a lead is told its invoice is waiting for the company''s signature');
  perform login(v_claire);
  perform assert(not exists (select 1 from notifications
                              where kind = 'invoice_signed_by_apporteur'
                                and payload ->> 'invoice_id' = v_inv.id::text),
    'and only them, not every admin');
end $$;

reset role;
set role service_role;
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_n      int;
  v_mail   jsonb;
begin
  -- a reminder whose time has come
  select id into v_reco from recommendations where filleul_first_name = 'Alerte';
  insert into reminders (recommendation_id, created_by, label, due_at)
  values (v_reco, v_pierre, 'Relancer Alerte Admin', now() - interval '1 minute');
  select dispatch_due_reminders() into v_n;
  perform assert(v_n >= 1, 'a reminder that is due is dispatched by the server');
  perform assert(exists (select 1 from notifications
                          where profile_id = v_pierre and kind = 'reminder_due'
                            and payload ->> 'label' = 'Relancer Alerte Admin'),
    'to whoever set it, wherever they are signed in');
  perform assert(dispatch_due_reminders() = 0, 'and only once');

  v_mail := notification_email((select id from notifications
                                 where profile_id = v_pierre and kind = 'reminder_due' limit 1));
  perform assert(v_mail ->> 'to' = 'pierre-louis@trinity-energie.test'
                 and v_mail ->> 'title' = 'Relance',
    'the email says the same thing as the push, to the right address');

  update profiles set email_notifications = false where id = v_pierre;
  perform assert(notification_email((select id from notifications
                                      where profile_id = v_pierre and kind = 'reminder_due' limit 1)) is null,
    'and nothing is emailed to someone who turned email off');
  update profiles set email_notifications = true where id = v_pierre;
end $$;

reset role;
insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999999', 'invitee@example.test');
set role authenticated;

\echo ''
\echo '=== 49. Invitations arrive by email; prospects can be forgotten ==='
do $$
declare
  v_johann  uuid := '11111111-1111-1111-1111-111111111111';
  v_marie   uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre  uuid := '33333333-3333-3333-3333-333333333333';
  v_invitee uuid := '99999999-9999-9999-9999-999999999999';
  v_reco    uuid;
  v_path    text;
  v_paths   text[];
  v_export  jsonb;
  v_prof    profiles%rowtype;
begin
  perform assert_denied(v_pierre, 'select create_invite()',
    'an invitation names the address it is sent to');
  perform assert_denied(v_pierre, 'select create_invite(''johann@example.test'')',
    'and is not sent to someone who already has an account');

  perform login(v_pierre);
  perform create_invite('invitee@example.test');
  perform login(v_invitee);
  select * into v_prof from redeem_invite(null, 'Nina', 'Invitée');
  perform assert(v_prof.role = 'apporteur' and v_prof.status = 'active',
    'whoever opens the invitation email joins with no code to type');

  -- a prospect who asks to be forgotten
  perform login(v_johann);
  insert into recommendations (filleul_first_name, filleul_last_name, filleul_phone,
                               filleul_email, parrain_id, consent_confirmed_at)
  values ('Oubli', 'Demande', '0611119999', 'oubli@example.test', v_johann, now())
  returning id into v_reco;
  v_path := v_reco || '/' || gen_random_uuid() || '.pdf';
  insert into storage.objects (bucket_id, name, owner) values ('documents', v_path, v_johann);
  perform register_document(v_reco, v_path, 'facture.pdf', 1000, 'application/pdf');

  perform login(v_pierre);
  v_export := filleul_data_export('06 11 11 99 99', null);
  perform assert(jsonb_array_length(v_export) = 1
                 and v_export -> 0 ->> 'email' = 'oubli@example.test'
                 and jsonb_array_length(v_export -> 0 -> 'documents') = 1,
    'everything held about a prospect can be produced on request, documents included');
  perform assert_denied(v_johann, 'select filleul_data_export(''0611119999'')',
    'by the company, not by an apporteur');

  perform assert_denied(v_johann, format('select erase_filleul(%L)', v_reco),
    'an apporteur cannot erase a prospect');
  perform login(v_pierre);
  v_paths := erase_filleul(v_reco);
  perform assert(v_paths = array[v_path], 'erasing hands back the files to delete from storage');
  perform assert(
    (select filleul_last_name = 'anonymisé' and filleul_phone is null and filleul_email is null
       from recommendations where id = v_reco),
    'and the prospect''s details are gone from the lead');
  perform assert(not exists (select 1 from documents where recommendation_id = v_reco),
    'with their documents');
  perform assert(jsonb_array_length(filleul_data_export('0611119999', null)) = 0,
    'so a second request finds nothing');

  -- an apporteur's own data
  perform login(v_johann);
  v_export := export_my_data();
  perform assert(v_export -> 'profile' ->> 'email' = 'johann@example.test'
                 and jsonb_array_length(v_export -> 'recommendations') > 0
                 and jsonb_array_length(v_export -> 'invoices') > 0,
    'an apporteur can take everything held about them in one file');
  perform assert(v_export -> 'profile' -> 'bank_details_reference' is null,
    'without the company''s internal reference');

  perform login(v_johann);
  perform report_diagnostic('crash', '1.0 (7)', 'iOS 26.0', '{"signal": "SIGABRT"}');
  perform login(v_pierre);
  perform assert(exists (select 1 from client_diagnostics where kind = 'crash' and profile_id = v_johann),
    'a crash on a phone reaches the company');
  perform login(v_johann);
  perform assert((select count(*) from client_diagnostics) = 0,
    'and only the company reads crash reports');
end $$;

reset role;
set role service_role;
do $$
declare v_result jsonb;
begin
  -- leads lost long ago are anonymised by the monthly sweep
  update recommendations set archived_at = now() - interval '4 years'
   where status = 'archived_lost';
  v_result := purge_stale_leads();
  perform assert((v_result ->> 'anonymised')::int >= 1,
    'a lead lost for longer than the retention period is anonymised');
  perform assert(not exists (select 1 from recommendations
                              where status = 'archived_lost' and filleul_phone is not null
                                and archived_at < now() - interval '3 years'),
    'all of them');
  perform assert((purge_stale_leads() ->> 'anonymised')::int = 0, 'and only once');
end $$;

reset role;
-- the send-sms function, as deployed: SMS is now part of signing
insert into edge_hooks (name, url, secret)
values ('send-sms', 'https://project.supabase.co/functions/v1/send-sms', 'sms-secret');

-- the plaintext of the last code sent: only the SMS carries it
create or replace function test_last_sms_code() returns text language sql as $$
  select substring(body ->> 'text' from '([0-9]{6})') from net.sent_requests
   where url like '%/send-sms' order by id desc limit 1;
$$;
-- codes asked for in an earlier block are older than the half-minute wait
create or replace function test_age_sms_codes() returns void
language sql security definer as $$
  update sms_codes set created_at = created_at - interval '1 minute';
$$;
grant execute on function test_age_sms_codes() to authenticated;
set role authenticated;

\echo ''
\echo '=== 50. A signature takes a code sent to a verified mobile ========'
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_reco   uuid;
  v_inv    invoices%rowtype;
  v_r      jsonb;
  v_code   text;
  v_req    net.sent_requests%rowtype;
begin
  perform assert(normalise_mobile('06 12 34 56 78') = '+33612345678'
                 and normalise_mobile('0033 7.12.34.56.78') = '+33712345678'
                 and normalise_mobile('+44 7700 900123') = '+447700900123',
    'a mobile number is understood however it is typed');
  perform assert(normalise_mobile('01 23 45 67 89') is null and normalise_mobile('hello') is null,
    'and a landline or nonsense is not a mobile');
  perform assert(mask_phone('+33612345678') = '+33 6 •• •• •• 78',
    'a number is shown masked, recognisable to its owner only');

  v_reco := test_reco_at_reward(v_johann, v_pierre, 70, 'Sms');
  select * into v_inv from issue_invoice(v_reco);

  perform login(v_johann);
  v_r := my_sms_status();
  perform assert((v_r ->> 'sms_required')::boolean and not (v_r ->> 'phone_verified')::boolean,
    'once SMS is set up, the app knows a signature needs a verified mobile');
  perform assert_denied(v_johann,
    format('update profiles set phone_verified_at = now() where id = %L', v_johann),
    'nobody can mark their own number verified');
  perform assert_denied(v_johann,
    format('select request_sms_code(''sign_invoice'', %L)', v_inv.id),
    'no signing code goes to a number that has not been proven');
  perform assert_denied(v_johann,
    format('select sign_invoice(%L, %L)', v_inv.id, v_inv.document_sha256),
    'and without one the apporteur cannot sign');
  perform assert_denied(v_johann,
    'select request_sms_code(''verify_phone'', null, ''01 23 45 67 89'')',
    'a code is only sent to a mobile');

  perform login(v_johann);
  v_r := request_sms_code('verify_phone', null, '06 12 34 56 78');
  perform assert(v_r ->> 'masked_phone' = '+33 6 •• •• •• 78', 'a code goes to the number typed');
  select * into v_req from net.sent_requests order by id desc limit 1;
  perform assert(v_req.url like '%/send-sms' and v_req.body ->> 'to' = '+33612345678'
                 and v_req.headers ->> 'x-hook-secret' = 'sms-secret',
    'through the send-sms function, in international form, with the shared secret');
  v_code := test_last_sms_code();

  v_r := confirm_sms_code('verify_phone', case when v_code = '000000' then '111111' else '000000' end);
  perform assert(not (v_r ->> 'ok')::boolean and v_r ->> 'reason' = 'wrong'
                 and (v_r ->> 'attempts_left')::int = 4,
    'a wrong code is refused, and counted');
  v_r := confirm_sms_code('verify_phone', v_code);
  perform assert((v_r ->> 'ok')::boolean, 'the right one proves the number');
  perform assert((select phone = '+33612345678' and phone_verified_at is not null
                    from profiles where id = v_johann),
    'which is now the verified number on the profile');
  perform assert(confirm_sms_code('verify_phone', v_code) ->> 'reason' = 'expired',
    'a code works once');
  perform assert_denied(v_johann, 'select request_sms_code(''verify_phone'', null, ''0612345678'')',
    'and codes cannot be asked for back to back');
  perform assert_denied(v_johann, 'select * from sms_codes',
    'nobody reads the codes table');
end $$;

do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_inv    invoices%rowtype;
  v_r      jsonb;
  v_code   text;
  i        int;
begin
  perform test_age_sms_codes();
  perform login(v_johann);
  select * into v_inv from invoices i
   where i.apporteur_id = v_johann and i.status in ('draft', 'awaiting_signatures')
     and exists (select 1 from recommendations r where r.id = i.recommendation_id
                  and r.filleul_first_name = 'Sms');

  perform login(v_johann);
  v_r := request_sms_code('sign_invoice', v_inv.id);
  perform assert((v_r ->> 'required')::boolean and v_r ->> 'masked_phone' = '+33 6 •• •• •• 78',
    'a signing code goes to the verified number');
  v_code := test_last_sms_code();
  select count(*) into i from net.sent_requests where url like '%/send-sms';
  v_r := request_sms_code('sign_invoice', v_inv.id);
  perform assert((v_r ->> 'reused')::boolean
                 and (select count(*) from net.sent_requests where url like '%/send-sms') = i,
    'coming back to the code screen does not send a second SMS while the first is good');

  for i in 1..5 loop
    v_r := confirm_sms_code('sign_invoice', '99999' || i::text, v_inv.id);
  end loop;
  perform assert(v_r ->> 'reason' = 'locked', 'five wrong codes lock it');
  perform assert(not (confirm_sms_code('sign_invoice', v_code, v_inv.id) ->> 'ok')::boolean,
    'after which even the right code is refused');
  perform assert_denied(v_johann,
    format('select sign_invoice(%L, %L)', v_inv.id, v_inv.document_sha256),
    'and the invoice stays unsigned');
end $$;

do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_marie  uuid := '22222222-2222-2222-2222-222222222222';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_inv    invoices%rowtype;
  v_sig    invoice_signatures%rowtype;
  v_second invoices%rowtype;
  v_code   text;
  v_doc    jsonb;
begin
  perform test_age_sms_codes();
  perform login(v_johann);
  select * into v_inv from invoices i
   where i.apporteur_id = v_johann and i.status in ('draft', 'awaiting_signatures')
     and exists (select 1 from recommendations r where r.id = i.recommendation_id
                  and r.filleul_first_name = 'Sms');

  perform login(v_johann);
  perform request_sms_code('sign_invoice', v_inv.id, null, true);
  v_code := test_last_sms_code();
  perform login(v_marie);
  perform assert(not (confirm_sms_code('sign_invoice', v_code, v_inv.id) ->> 'ok')::boolean,
    'a code is bound to its owner');

  perform login(v_johann);
  perform assert((confirm_sms_code('sign_invoice', ' ' || v_code || ' ', v_inv.id) ->> 'ok')::boolean,
    'the right code, pasted with spaces, confirms the signature');
  select * into v_sig from sign_invoice(v_inv.id, v_inv.document_sha256);
  perform assert(v_sig.otp_verified and v_sig.otp_phone = '+33 6 •• •• •• 78',
    'the signature keeps that it was confirmed by SMS, and to which number');

  -- a second invoice, in the same ten minutes: no second SMS
  select * into v_second from issue_invoice(test_reco_at_reward(v_johann, v_pierre, 45, 'Fenetre'));
  perform login(v_johann);
  perform assert((request_sms_code('sign_invoice', v_second.id) ->> 'session')::boolean,
    'a confirmed code covers the next signatures for ten minutes, without another SMS');
  select * into v_sig from sign_invoice(v_second.id, v_second.document_sha256);
  perform assert(v_sig.otp_verified and v_sig.otp_phone = '+33 6 •• •• •• 78',
    'and each of them records it');

  perform login(v_pierre);
  select * into v_sig from sign_invoice(v_inv.id, v_inv.document_sha256);
  perform assert(not v_sig.otp_verified, 'the company signs from its own session, without a code');
  v_doc := invoice_document(v_inv.id);
  perform assert((v_doc -> 'signatures' -> 0 ->> 'sms_verified')::boolean
                 and v_doc -> 'signatures' -> 0 ->> 'sms_phone' = '+33 6 •• •• •• 78'
                 and not (v_doc -> 'signatures' -> 1 ->> 'sms_verified')::boolean,
    'and the document says which signature was confirmed by SMS');

  perform login(v_johann);
  update profiles set phone = '07 00 00 00 01' where id = v_johann;
  perform assert((select phone_verified_at is null from profiles where id = v_johann),
    'changing the number takes the verification away');
  perform assert(not (my_sms_status() ->> 'phone_verified')::boolean,
    'and the app asks for it again');
end $$;

reset role;
do $$
begin
  perform assert(not exists (select 1 from sms_codes where code_hash !~ '^[0-9a-f]{64}$'),
    'a code is kept only as a hash, never as itself');
  insert into sms_codes (profile_id, purpose, phone, code_hash, expires_at, created_at)
  select '11111111-1111-1111-1111-111111111111', 'verify_phone', '+33700000001', 'x',
         now(), now() - interval '5 minutes'
    from generate_series(1, 6);
end $$;
set role authenticated;
do $$
begin
  perform assert_denied('11111111-1111-1111-1111-111111111111',
    'select request_sms_code(''verify_phone'', null, ''0700000001'')',
    'six codes in an hour is the most anyone is sent');
end $$;

\echo ''
\echo '=== 51. One SMS where one will do; no invoice without an address ===='
reset role;
do $$
declare v_text text;
begin
  -- what a phone receives fits in one SMS: GSM-7 only, at most 160
  foreach v_text in array array[sms_text('sign_invoice', '123456'), sms_text('verify_phone', '123456')] loop
    perform assert(length(v_text) <= 160
                   and v_text ~ '^[A-Za-z0-9 @£$¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ!"#¤%&''()*+,\-./:;<=>?¡ÄÖÑÜ§¿äöñüà]*$',
      format('"%s" is one SMS', v_text));
  end loop;
end $$;
insert into auth.users (id, email) values ('12121212-1212-1212-1212-121212121212', 'lucas@example.test');
insert into profiles (id, role, status, first_name, last_name, email, city, address, postal_code,
                      billing_mandate_signed_at)
values ('12121212-1212-1212-1212-121212121212', 'apporteur', 'active', 'Lucas', 'Martin',
        'lucas@example.test', 'Douai', '4 rue de Paris', '59500', timestamptz '2026-01-05 10:00');
set role authenticated;

do $$
declare
  v_eva    uuid := '12121212-1212-1212-1212-121212121212';   -- Lucas
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_inv    invoices%rowtype;
  v_sig    invoice_signatures%rowtype;
  v_r      jsonb;
  v_before bigint;
  v_text   text;
begin
  -- Lucas has never verified a number: his first signature proves it as well
  select * into v_inv from issue_invoice(test_reco_at_reward(v_eva, v_pierre, 120, 'Premiere'));
  perform login(v_eva);
  perform assert_denied(v_eva, format('select request_sms_code(''sign_invoice'', %L)', v_inv.id),
    'with no proven number, the app has to ask for one');
  perform login(v_eva);
  select coalesce(max(id), 0) into v_before from net.sent_requests;
  v_r := request_sms_code('sign_invoice', v_inv.id, '07 11 22 33 44');
  perform assert((v_r ->> 'required')::boolean and v_r ->> 'masked_phone' = '+33 7 •• •• •• 44'
                 and (select count(*) from net.sent_requests where id > v_before) = 1,
    'the signing code goes to the number she types: one SMS');
  perform assert((confirm_sms_code('sign_invoice', test_last_sms_code(), v_inv.id) ->> 'ok')::boolean,
    'and the code she types back');
  perform assert((select phone = '+33711223344' and phone_verified_at is not null
                    from profiles where id = v_eva),
    'proves the number and confirms the signature at once');
  select * into v_sig from sign_invoice(v_inv.id, v_inv.document_sha256);
  perform assert(v_sig.otp_verified and v_sig.otp_phone = '+33 7 •• •• •• 44', 'she has signed');

  -- the address
  reset role;
  update profiles set address = null where id = v_eva;
  set role authenticated;
  perform login(v_pierre);
  begin
    perform issue_invoice(test_reco_at_reward(v_eva, v_pierre, 90, 'SansAdresse'));
    perform assert(false, 'an apporteur without a billing address cannot be invoiced');
  exception when others then
    get stacked diagnostics v_text = pg_exception_hint;
    perform assert(v_text = 'apporteur_address_missing',
      'an apporteur without a billing address cannot be invoiced, and the admin is told why');
  end;
  reset role;
  update profiles set address = '4 rue de Paris' where id = v_eva;
  set role authenticated;
end $$;

do $$
begin
  perform assert(notification_body('invoice_ready', '{"number":"FA-2026-0009","amount":"12500.00"}')
                   = 'Facture FA-2026-0009 — 12 500,00 €',
    'a notification writes an amount the French way');
  perform assert(notification_body('payment_sent', '{"amount":"300.5"}') = '300,50 € en route',
    'cents included');
  perform assert((select count(*) from stages where banner_template like '%onglet Documents%') = 0,
    'no banner points to a Documents tab the app does not have');
end $$;

reset role;
delete from edge_hooks where name = 'send-sms';
set role authenticated;
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_inv    invoices%rowtype;
  v_sig    invoice_signatures%rowtype;
begin
  perform login(v_pierre);
  select * into v_inv from issue_invoice(test_reco_at_reward(v_johann, v_pierre, 60, 'SansSms'));
  perform login(v_johann);
  perform assert(not (request_sms_code('sign_invoice', v_inv.id) ->> 'required')::boolean,
    'until SMS is set up, no code is asked for');
  select * into v_sig from sign_invoice(v_inv.id, v_inv.document_sha256);
  perform assert(not v_sig.otp_verified, 'and signing works as before');
end $$;


\echo ''
\echo '=== 52. Approved, lost, countersigned: the apporteur is told ======'
reset role;
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000052', 'nadia@example.test');
insert into profiles (id, role, status, first_name, last_name, email)
values ('aaaaaaaa-0000-0000-0000-000000000052', 'apporteur', 'pending', 'Nadia', 'Nouvelle',
        'nadia@example.test');
set role authenticated;
do $$
declare
  v_johann uuid := '11111111-1111-1111-1111-111111111111';
  v_pierre uuid := '33333333-3333-3333-3333-333333333333';
  v_nadia  uuid := 'aaaaaaaa-0000-0000-0000-000000000052';
  v_reco   uuid;
  v_won    uuid;
  v_inv    invoices%rowtype;
begin
  perform login(v_pierre);
  perform approve_member(v_nadia);
  perform login(v_nadia);
  perform assert(exists (select 1 from notification_feed
                          where kind = 'member_approved' and title = 'Compte activé'),
    'an approved member is told their account is open');

  -- a lead closed as lost
  perform login(v_johann);
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id, consent_confirmed_at)
  values ('Sans', 'Suite', v_johann, now()) returning id into v_reco;
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id, consent_confirmed_at)
  values ('Bien', 'Conclu', v_johann, now()) returning id into v_won;
  perform login(v_pierre);
  perform archive_recommendation(v_reco, false);
  perform archive_recommendation(v_won, true);
  perform login(v_johann);
  perform assert(exists (select 1 from notification_feed
                          where kind = 'recommendation_lost' and recommendation_id = v_reco
                            and body = 'Le dossier de Sans Suite est clôturé sans suite.'),
    'the apporteur learns a lead went nowhere, and which one');
  perform assert(not exists (select 1 from notification_feed
                              where kind = 'recommendation_lost' and recommendation_id = v_won),
    'and a won one is not called lost');

  -- the company countersigns
  perform login(v_pierre);
  select * into v_inv from issue_invoice(test_reco_at_reward(v_johann, v_pierre, 75, 'Contresigne'));
  perform login(v_johann);
  perform sign_invoice(v_inv.id, v_inv.document_sha256);
  perform assert(not exists (select 1 from notification_feed
                              where kind = 'invoice_signed' and invoice_id = v_inv.id),
    'their own signature alone completes nothing');
  perform login(v_pierre);
  perform sign_invoice(v_inv.id, v_inv.document_sha256);
  perform login(v_johann);
  perform assert((select count(*) from notification_feed
                   where kind = 'invoice_signed' and invoice_id = v_inv.id) = 1,
    'once the company has signed too, the apporteur is told, once');
  perform assert(exists (select 1 from notification_feed
                          where kind = 'invoice_signed' and invoice_id = v_inv.id
                            and body like 'Facture ' || v_inv.number || ' signée des deux parties — 75,00 €'),
    'with the invoice and its amount, written the French way');
end $$;

reset role;
set role service_role;
do $$
declare v_nadia uuid := 'aaaaaaaa-0000-0000-0000-000000000052';
begin
  perform assert(
    notification_email((select id from notifications
                         where profile_id = v_nadia and kind = 'member_approved')) ->> 'to'
      = 'nadia@example.test',
    'the approval goes by email too: they may not have the app open yet');
  perform assert(not is_email_worthy('recommendation_lost') and not is_email_worthy('invoice_signed'),
    'a lost lead is not mailed, and the countersigned invoice already is, with its PDF');
end $$;

reset role;
\echo ''
\echo '=== ALL ASSERTIONS PASSED ========================================='
