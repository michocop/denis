#!/usr/bin/env bash
# Applies the migrations to a throwaway database and runs the RLS test suite.
# Usage: scripts/db_test.sh [psql connection flags...]
set -euo pipefail

PSQL_ARGS=("$@")
DB="energy_courtage_test_$$"

cleanup() { psql "${PSQL_ARGS[@]}" -q -c "drop database if exists $DB;" >/dev/null 2>&1 || true; }
trap cleanup EXIT

psql "${PSQL_ARGS[@]}" -q -c "create database $DB;"

run() { psql "${PSQL_ARGS[@]}" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$1"; }

run supabase/local/00_auth_shim.sql
for f in supabase/migrations/*.sql; do
  echo "  applying $(basename "$f")"
  run "$f"
done

psql "${PSQL_ARGS[@]}" -d "$DB" -v ON_ERROR_STOP=1 -f supabase/tests/rls_test.sql
