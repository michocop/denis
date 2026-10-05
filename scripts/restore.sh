#!/usr/bin/env bash
# Opens a backup made by scripts/backup.sh, and optionally loads it.
#
#   scripts/restore.sh <archive.tar.gz.enc>                  # decrypt and unpack, nothing else
#   scripts/restore.sh <archive.tar.gz.enc> --into <db-url>  # and load the tables into a database
#
# Loading is meant for a fresh database that already has the schema (the
# migrations: `supabase db push`, or scripts/db_test.sh's setup locally). Rows
# go in table by table with triggers and foreign keys held off, as a restore
# must: the data was consistent when it was taken. Accounts come back without
# passwords; each person uses "Mot de passe oublié". Stored files are left in
# the unpacked folder, to upload with `supabase storage cp`.
set -euo pipefail

ARCHIVE="${1:?usage: scripts/restore.sh <archive.tar.gz.enc> [--into <db-url>]}"
PASS="${BACKUP_PASSPHRASE:-$(security find-generic-password -s trinity-energie-backup -w)}"
OUT="${ARCHIVE%.tar.gz.enc}"
mkdir -p "$OUT"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "pass:$PASS" -in "$ARCHIVE" | tar -C "$OUT" -xzf -
DIR="$(find "$OUT" -name manifest.json -maxdepth 2 -exec dirname {} \; | head -1)"
echo "Unpacked: $DIR"
cat "$DIR/manifest.json"

[ "${2:-}" = "--into" ] || exit 0
DB="${3:?--into needs a database URL}"

python3 - "$DIR" > "$DIR/restore.sql" <<'PY'
import json, os, sys
d = sys.argv[1]
tables = sorted(f[:-5] for f in os.listdir(f"{d}/tables") if f.endswith(".json") and not f.startswith("auth."))
print("set session_replication_role = replica;")
print("begin;")
users = json.load(open(f"{d}/tables/auth.users.json")) or []
for u in users:
    email = "'" + u["email"].replace("'", "''") + "'" if u.get("email") else "null"
    print(f"insert into auth.users (id, email, created_at) values ('{u['id']}', {email}, '{u['created_at']}') "
          "on conflict (id) do nothing;")
for t in tables:
    rows = json.load(open(f"{d}/tables/{t}.json")) or []
    if not rows: continue
    print(f"delete from public.\"{t}\";")
    print(f"insert into public.\"{t}\" select * from json_populate_recordset(null::public.\"{t}\", $j${json.dumps(rows)}$j$::json);")
print("commit;")
print("set session_replication_role = default;")
PY
psql "$DB" -v ON_ERROR_STOP=1 -q -f "$DIR/restore.sql"
echo "Loaded into the database. Files to re-upload: $DIR/storage"
