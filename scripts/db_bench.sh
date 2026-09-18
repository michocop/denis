#!/usr/bin/env bash
# Loads a synthetic 2 000-apporteur / 40 000-recommendation database and times
# the queries the app actually makes. Run it after any schema change: the whole
# point is that these numbers stay boring.
set -euo pipefail

PSQL_ARGS=("$@")
DB="energy_courtage_bench"

psql "${PSQL_ARGS[@]}" -q -c "drop database if exists $DB;"
psql "${PSQL_ARGS[@]}" -q -c "create database $DB;"

run() { psql "${PSQL_ARGS[@]}" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$1"; }
run supabase/local/00_auth_shim.sql
for f in supabase/migrations/*.sql; do run "$f"; done
run supabase/bench/load.sql

psql "${PSQL_ARGS[@]}" -d "$DB" -q -c "
  insert into auth.users(id,email)
    values ('99999999-9999-9999-9999-999999999999','admin@bench.test')
    on conflict do nothing;
  insert into profiles(id,role,status,first_name,last_name,email)
    values ('99999999-9999-9999-9999-999999999999','admin','active',
            'Pierre-Louis','Tettamanti','admin@bench.test')
    on conflict do nothing;"

APPORTEUR=$(psql "${PSQL_ARGS[@]}" -d "$DB" -tAc \
  "select id from profiles where email like 'bench%' limit 1")

psql "${PSQL_ARGS[@]}" -d "$DB" -q <<SQL
\timing on
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"$APPORTEUR"}', false);
\echo '--- apporteur: list ---'
select count(*) from recommendation_page(false, null, null, null, 20);
\echo '--- apporteur: dashboard ---'
select dashboard_stats();
select set_config('request.jwt.claims', '{"sub":"99999999-9999-9999-9999-999999999999"}', false);
\echo '--- admin: first page ---'
select count(*) from recommendation_page(false, null, null, null, 20);
\echo '--- admin: dashboard over everything ---'
select dashboard_stats();
\echo '--- admin: search by filleul ---'
select count(*) from recommendation_page(false, 'Client1234', null, null, 20);
\echo '--- admin: search by apporteur ---'
select count(*) from recommendation_page(false, 'Nom42', null, null, 20);
\echo '--- admin: archived ---'
select count(*) from recommendation_page(true, null, null, null, 20);
SQL

psql "${PSQL_ARGS[@]}" -q -c "drop database $DB;"
