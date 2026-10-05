#!/usr/bin/env bash
# Connects SMS codes (Brevo) to a Supabase project, in one go.
#
#   scripts/link_sms.sh <project-ref>
#
# What it does, and what it asks you for:
#   1. installs the Supabase CLI into .devtools/ if it is not on PATH
#   2. signs you in to Supabase (a browser window, once) and links the project
#   3. asks for the Brevo API key -- typed hidden, never echoed or written to disk
#   4. stores it as a function secret, with a fresh shared secret for the hook
#   5. deploys the send-sms function
#   6. points the database at it (edge_hooks), which switches SMS on for signing
#   7. optionally sends you a test SMS
#
# Re-running it is safe: it rotates the hook secret and redeploys.
# To switch SMS off again:  update edge_hooks set enabled = false where name = 'send-sms';
set -euo pipefail

REF="${1:-}"
if [ -z "$REF" ]; then
  echo "usage: scripts/link_sms.sh <project-ref>   (the ref is in your project URL: https://<ref>.supabase.co)" >&2
  exit 2
fi

cd "$(dirname "$0")/.."
DT="$PWD/.devtools"

# ------------------------------------------------------------ 1. the CLI
if command -v supabase >/dev/null 2>&1; then
  SB="supabase"
else
  SB="$DT/supabase/supabase"
  if [ ! -x "$SB" ]; then
    echo "==> Installing the Supabase CLI into .devtools/supabase"
    mkdir -p "$DT/supabase"
    case "$(uname -m)" in arm64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac
    curl -fsSL "https://github.com/supabase/cli/releases/latest/download/supabase_darwin_${ARCH}.tar.gz" \
      | tar -xz -C "$DT/supabase" supabase
    xattr -d com.apple.quarantine "$SB" 2>/dev/null || true
  fi
fi
echo "==> $("$SB" --version 2>/dev/null | head -1)"

# ------------------------------------------------------- 2. sign in, link
if ! "$SB" projects list >/dev/null 2>&1; then
  echo "==> Signing in to Supabase (a browser window opens)"
  "$SB" login
fi
"$SB" link --project-ref "$REF"

has_table() {
  "$SB" db query --linked -o csv "select to_regclass('public.edge_hooks') is not null as ok" 2>/dev/null \
    | grep -qiE '^(t|true)$'
}
if ! has_table; then
  echo
  echo "The database has no edge_hooks table yet: the schema has not been pushed."
  read -r -p "Push all migrations now (supabase db push)? [Y/n] " push </dev/tty
  if [ "$push" != "n" ] && [ "$push" != "N" ]; then
    "$SB" db push --linked --yes
  else
    echo "Push the migrations first, then run this again." >&2
    exit 1
  fi
fi

# ----------------------------------------------------- 3. the Brevo key
echo
echo "Brevo API key: brevo.com → SMTP & API → API Keys → Generate a new API key."
read -r -s -p "Paste it here (hidden): " BREVO_KEY </dev/tty
echo
case "$BREVO_KEY" in
  xkeysib-*) ;;
  *) echo "That does not look like a Brevo API key (they start with xkeysib-)." >&2; exit 1 ;;
esac

# a quick check the key works, before anything depends on it
if ! curl -fsS -o /dev/null -H "api-key: $BREVO_KEY" https://api.brevo.com/v3/account; then
  echo "Brevo refused that key." >&2
  exit 1
fi

SENDER="${SMS_SENDER:-Trinity}"
HOOK_SECRET="$(openssl rand -hex 32)"

# ------------------------------------------------ 4. secrets, 5. deploy
echo "==> Storing the secrets"
# through a file descriptor, so the key never appears in the process list
"$SB" secrets set --project-ref "$REF" --env-file <(printf 'BREVO_API_KEY=%s\nSEND_SMS_HOOK_SECRET=%s\nSMS_SENDER=%s\n' \
  "$BREVO_KEY" "$HOOK_SECRET" "$SENDER") >/dev/null
unset BREVO_KEY

echo "==> Deploying send-sms"
"$SB" functions deploy send-sms --project-ref "$REF" --no-verify-jwt

# ------------------------------------------------ 6. switch it on
echo "==> Pointing the database at it"
"$SB" db query --linked "
  insert into edge_hooks (name, url, secret)
  values ('send-sms', 'https://$REF.supabase.co/functions/v1/send-sms', '$HOOK_SECRET')
  on conflict (name) do update
    set url = excluded.url, secret = excluded.secret, enabled = true, updated_at = now();" >/dev/null

# ------------------------------------------------ 7. a test SMS
echo
read -r -p "Send a test SMS? Number in international form (+33612345678), or Enter to skip: " TO </dev/tty
if [ -n "$TO" ]; then
  curl -sS -X POST "https://$REF.supabase.co/functions/v1/send-sms" \
    -H "content-type: application/json" -H "x-hook-secret: $HOOK_SECRET" \
    -d "{\"to\":\"$TO\",\"text\":\"Trinity Énergie : les codes de signature par SMS sont activés.\"}"
  echo
fi

echo
echo "Done. Apporteurs now sign invoices with a code sent by SMS."
echo "Each will be asked to verify their mobile once (Profil → Vérifier mon mobile)."
