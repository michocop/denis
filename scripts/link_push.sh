#!/usr/bin/env bash
# Switches on push notifications, from the Apple key file, in one go.
#
#   scripts/link_push.sh ~/Downloads/AuthKey_ABC123DEFG.p8
#
# The key: developer.apple.com → Certificates, IDs & Profiles → Keys → "+",
# tick "Apple Push Notifications service (APNs)", Continue, Register, Download.
# Apple lets you download it once; keep the file somewhere safe.
#
# What it does:
#   1. reads the key id from the file name (AuthKey_<id>.p8)
#   2. stores the key as a function secret -- through a file descriptor, never
#      on the command line or on screen
#   3. switches the send-push hook on (scripts/deploy.sh registered it, off)
#
# Re-running it with a new key replaces the old one.
set -euo pipefail

KEY="${1:-}"
if [ -z "$KEY" ] || [ ! -f "$KEY" ]; then
  echo "usage: scripts/link_push.sh path/to/AuthKey_XXXXXXXXXX.p8" >&2
  exit 2
fi
KEY_ID="$(basename "$KEY" | sed -n 's/^AuthKey_\([A-Z0-9]\{10\}\)\.p8$/\1/p')"
[ -n "$KEY_ID" ] || { echo "Expected Apple's file name, AuthKey_<10 characters>.p8" >&2; exit 2; }
grep -q "BEGIN PRIVATE KEY" "$KEY" || { echo "$KEY is not an Apple .p8 key" >&2; exit 2; }

cd "$(dirname "$0")/.."
export SEND_EMAIL_HOOK_SECRET="$(sed -n 's/^SEND_EMAIL_HOOK_SECRET=//p' supabase/.env)"
SB="$(command -v supabase || echo "$PWD/.devtools/supabase/supabase")"
REF="$(sed -n 's/^project_id = "\(.*\)"/\1/p' supabase/config.toml)"
TEAM="$(sed -n 's/^ *DEVELOPMENT_TEAM: *//p' ios/project.yml | head -1)"

echo "==> Storing the key ($KEY_ID, team $TEAM)"
# the key's body on one line: send-push strips the PEM header and whitespace
"$SB" secrets set --project-ref "$REF" --env-file <(printf 'APNS_KEY_ID=%s\nAPNS_TEAM_ID=%s\nAPNS_PRIVATE_KEY=%s\n' \
  "$KEY_ID" "$TEAM" "$(grep -v -- '-----' "$KEY" | tr -d '\n\r ')") >/dev/null

echo "==> Switching push on"
"$SB" db query --linked "update edge_hooks set enabled = true, updated_at = now() where name = 'send-push'
                         returning name, enabled" -o csv </dev/null | tail -1

echo
echo "Done. Each phone that allowed notifications gets them from the next event on"
echo "(a new recommendation, a stage, an invoice to sign, a message)."
