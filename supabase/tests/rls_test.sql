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
  insert into recommendations (filleul_first_name, filleul_last_name, parrain_id)
  values ('Claire', 'Petit', v_marie)
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
                               filleul_phone, parrain_id, reward_amount)
  values ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Luc', 'Martin',
          '0600000001', v_johann, 750)
  returning id into v_reco;

  perform mark_notifications_read();

  perform login(v_pierre);
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
                               parrain_id, created_at)
  select 'Page', 'Test' || g, '0620000' || lpad(g::text, 3, '0'), v_johann,
         now() - (g || ' hours')::interval
  from generate_series(1, 25) g;

  perform login(v_pierre);
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
             where profile_id = v_johann and kind = 'payout_sent'),
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

reset role;
\echo ''
\echo '=== ALL ASSERTIONS PASSED ========================================='
