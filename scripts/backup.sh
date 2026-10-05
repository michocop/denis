#!/usr/bin/env bash
# Nightly backup of the production project: every table, every stored file.
#
#   scripts/backup.sh             # one backup now
#   scripts/backup.sh --install   # and every night at 02:30, on this Mac
#   scripts/backup.sh --uninstall
#
# What a backup is: the schema is the migrations in this repository; the data
# is each table exported as JSON through the Supabase API (HTTPS, with the CLI's
# own sign-in -- no database password is stored anywhere); the files are the
# `invoices` and `documents` buckets. All of it goes into one archive,
# encrypted (AES-256) with a passphrase kept in this Mac's Keychain:
#   security find-generic-password -s trinity-energie-backup -w
# Keep a copy of that passphrase somewhere safe: without it no backup opens.
#
# Archives land in iCloud Drive (an off-site copy) when it is on, in Documents
# otherwise, and the last 30 are kept. Each run is also activity on the
# project, so a free-plan project is never paused for inactivity.
#
# Restore: scripts/restore.sh <archive>
set -euo pipefail

REF="mfnauyfkhwjsxapqdtiu"
KEEP=30
HOME_DIR="$HOME/Library/Application Support/TrinityEnergieBackup"
LABEL="fr.trinity-energie.backup"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]; then
  DEST="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Trinity Énergie — sauvegardes"
else
  DEST="$HOME/Documents/Trinity Énergie — sauvegardes"
fi

# ---------------------------------------------------------------- install
# A background job may not read the Desktop (macOS privacy), so it runs from a
# copy of what it needs in Application Support: this script, the CLI, and the
# project's link.
if [ "${1:-}" = "--install" ]; then
  REPO="$(cd "$(dirname "$0")/.." && pwd)"
  mkdir -p "$HOME_DIR/supabase/.temp" "$HOME/Library/LaunchAgents" "$DEST"
  cp "$REPO/scripts/backup.sh" "$HOME_DIR/backup.sh"
  cp "$REPO/.devtools/supabase/supabase" "$HOME_DIR/supabase-cli"
  cp "$REPO/supabase/config.toml" "$HOME_DIR/supabase/config.toml"
  cp "$REPO/supabase/.env" "$HOME_DIR/supabase/.env" && chmod 600 "$HOME_DIR/supabase/.env"
  cp "$REPO"/supabase/.temp/* "$HOME_DIR/supabase/.temp/" 2>/dev/null || true
  chmod +x "$HOME_DIR/backup.sh" "$HOME_DIR/supabase-cli"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$HOME_DIR/backup.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>2</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key><string>$HOME_DIR/last-run.log</string>
  <key>StandardErrorPath</key><string>$HOME_DIR/last-run.log</string>
</dict></plist>
PL
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "Installed: every night at 02:30 (or at wake, if the Mac was asleep), into:"
  echo "  $DEST"
  exec "$HOME_DIR/backup.sh"
fi
if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Nightly backups stopped. Existing archives are kept in: $DEST"
  exit 0
fi

# -------------------------------------------------------------- run
if [ -x "$HOME_DIR/supabase-cli" ] && [ "$(dirname "$0")" = "$HOME_DIR" ]; then
  SB="$HOME_DIR/supabase-cli"; cd "$HOME_DIR"
else
  cd "$(dirname "$0")/.."; SB="$PWD/.devtools/supabase/supabase"
fi
export SEND_EMAIL_HOOK_SECRET="$(sed -n 's/^SEND_EMAIL_HOOK_SECRET=//p' supabase/.env)"

# the passphrase: made once, kept in the Keychain
if ! PASS="$(security find-generic-password -s trinity-energie-backup -w 2>/dev/null)"; then
  PASS="$(openssl rand -base64 33)"
  security add-generic-password -s trinity-energie-backup -a "$USER" -w "$PASS" \
    -j "Trinity Énergie backups (scripts/backup.sh)"
  echo "A backup passphrase was created and stored in the Keychain (trinity-energie-backup)."
fi

STAMP="$(date +%Y-%m-%d_%H%M)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$STAMP/tables" "$WORK/$STAMP/storage" "$DEST"

query() { "$SB" db query --linked -o json "$1" </dev/null 2>/dev/null; }
# The API wraps rows in an envelope; keep the first column of the first row.
first_value() { python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("rows",[]); print(json.dumps(list(r[0].values())[0] if r else None))'; }

# every table but the ones that hold nothing worth restoring or a live secret
tables="$(query "select string_agg(table_name, ' ' order by table_name) as t
                   from information_schema.tables
                  where table_schema = 'public' and table_type = 'BASE TABLE'
                    and table_name not in ('sms_codes', 'edge_hooks', 'push_config')" \
          | first_value | tr -d '"')"
count=0
for t in $tables; do
  query "select coalesce(json_agg(x), '[]'::json) from public.\"$t\" x" | first_value > "$WORK/$STAMP/tables/$t.json"
  count=$((count + 1))
done
# the accounts: who they are, not their passwords (a restored person resets it)
query "select coalesce(json_agg(x), '[]'::json) from (select id, email, phone, created_at,
         email_confirmed_at, raw_user_meta_data from auth.users) x" | first_value \
  > "$WORK/$STAMP/tables/auth.users.json"

for bucket in invoices documents; do
  "$SB" --experimental storage cp -r "ss:///$bucket" "$WORK/$STAMP/storage/$bucket" --linked \
    </dev/null >/dev/null 2>&1 || mkdir -p "$WORK/$STAMP/storage/$bucket"
done
files="$(find "$WORK/$STAMP/storage" -type f | wc -l | tr -d ' ')"

printf '{"project":"%s","taken_at":"%s","tables":%s,"files":%s}\n' \
  "$REF" "$(date -u +%FT%TZ)" "$count" "$files" > "$WORK/$STAMP/manifest.json"

ARCHIVE="$DEST/trinity-energie_$STAMP.tar.gz.enc"
tar -C "$WORK" -czf - "$STAMP" \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "pass:$PASS" -out "$ARCHIVE"

# keep the last $KEEP
ls -1t "$DEST"/trinity-energie_*.tar.gz.enc 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do rm -f "$old"; done

echo "$(date '+%F %T') backup: $count tables, $files files -> $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
