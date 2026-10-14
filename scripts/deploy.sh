#!/usr/bin/env bash
# One command: the backend in this repository, onto its Supabase project.
#
#   scripts/deploy.sh                 # the linked project (supabase/config.toml)
#   scripts/deploy.sh <project-ref>   # another one
#   scripts/deploy.sh --yes           # no questions (CI, or when you are sure)
#   scripts/deploy.sh --no-auth       # leave the project's auth settings alone
#
# In order, and safe to re-run:
#   1. the database tests, against a throwaway local database, if the local
#      tools are installed (scripts/dev_tools.sh) -- a red run stops here
#   2. the schema: every migration not yet applied
#   3. the server functions
#   4. the hooks between the database and the functions, each with a shared
#      secret (kept if it exists, created otherwise)
#   5. the auth settings from supabase/config.toml (sign-up closed, the app's
#      redirect URL), after showing what changes
#   6. a report of what still needs a key from you
#
# Keys for outside services are never asked for here. Paste them in the
# dashboard (Edge Functions → Secrets) or with `supabase secrets set`:
#   BREVO_API_KEY      SMS codes and emails (brevo.com → SMTP & API → API Keys)
#   MAIL_FROM          the sender, verified in Brevo (Senders), e.g.
#                      "Trinity Énergie <pierrelouis@trinity-energie.fr>"
#   RESEND_API_KEY     optional: emails through Resend instead of Brevo
#   APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY
#                      push notifications (Apple Developer → Keys → APNs): the
#                      push hook switches on once all three are set
set -euo pipefail

cd "$(dirname "$0")/.."
# supabase/config.toml signs the auth-email hook with env(SEND_EMAIL_HOOK_SECRET),
# and the CLI refuses every command while it is unset. The value lives in
# supabase/.env (git-ignored), which the CLI reads by itself, so every command
# -- these scripts or a hand-typed one -- uses the one the hook was given.
if ! grep -qs '^SEND_EMAIL_HOOK_SECRET=' supabase/.env; then
  printf 'SEND_EMAIL_HOOK_SECRET=v1,whsec_%s\n' "$(openssl rand -base64 32)" >> supabase/.env
  chmod 600 supabase/.env
fi
export SEND_EMAIL_HOOK_SECRET="$(sed -n 's/^SEND_EMAIL_HOOK_SECRET=//p' supabase/.env)"
DT="$PWD/.devtools"
YES=""
AUTH=1
REF=""
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES="--yes" ;;
    --no-auth) AUTH=0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) REF="$arg" ;;
  esac
done
[ -n "$REF" ] || REF="$(sed -n 's/^project_id = "\(.*\)"/\1/p' supabase/config.toml)"
[ -n "$REF" ] || { echo "No project: pass its ref, e.g. scripts/deploy.sh abcdefghijklmnop" >&2; exit 2; }

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
todo() { printf '    \033[33m•\033[0m %s\n' "$*"; }
ask()  {
  [ -n "$YES" ] && return 0
  local answer; read -r -p "    $1 [Y/n] " answer </dev/tty
  [ "$answer" != "n" ] && [ "$answer" != "N" ]
}

# ------------------------------------------------------------- the CLI
if command -v supabase >/dev/null 2>&1; then
  SB="supabase"
else
  SB="$DT/supabase/supabase"
  if [ ! -x "$SB" ]; then
    say "Installing the Supabase CLI into .devtools/supabase"
    mkdir -p "$DT/supabase"
    case "$(uname -m)" in arm64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac
    curl -fsSL "https://github.com/supabase/cli/releases/latest/download/supabase_darwin_${ARCH}.tar.gz" \
      | tar -xz -C "$DT/supabase" supabase
    xattr -d com.apple.quarantine "$SB" 2>/dev/null || true
  fi
fi

say "Project $REF"
if ! "$SB" projects list </dev/null >/dev/null 2>&1; then
  echo "    Signing in to Supabase (a browser window opens once)"
  "$SB" login
fi
"$SB" link --project-ref "$REF" </dev/null >/dev/null
ok "linked"

query() { "$SB" db query --linked -o json "$1" </dev/null 2>/dev/null; }

# ------------------------------------------------------- 1. the tests
if [ -f "$DT/env.sh" ]; then
  say "Database tests (local)"
  # shellcheck disable=SC1091
  source "$DT/env.sh"
  if pg_isready -q -h 127.0.0.1 -p 54329; then
    if scripts/db_test.sh -h 127.0.0.1 -p 54329 -U postgres > "$DT/last_db_test.log" 2>&1; then
      ok "$(grep -c PASS "$DT/last_db_test.log") assertions pass"
    else
      grep -E "ERROR|FAIL" "$DT/last_db_test.log" | head -5
      echo "    The tests fail: nothing was deployed. Full log: .devtools/last_db_test.log" >&2
      exit 1
    fi
  else
    todo "local Postgres is not running (scripts/dev_tools.sh starts it): tests skipped"
  fi
fi

# ------------------------------------------------------- 2. the schema
say "Schema"
pending="$("$SB" db push --linked --dry-run </dev/null 2>&1 | grep -c '^ •' || true)"
if [ "$pending" = "0" ]; then
  ok "up to date"
else
  "$SB" db push --linked --dry-run </dev/null 2>&1 | grep '^ •' || true
  if ask "Apply these $pending migration(s)?"; then
    "$SB" db push --linked --yes </dev/null 2>&1 | grep -E "Applying|ERROR|error" || true
    ok "applied"
  else
    echo "    Stopped before changing the database." >&2
    exit 1
  fi
fi

# ---------------------------------------------------- 3. the functions
say "Server functions"
deploy() {
  "$SB" functions deploy "$1" --project-ref "$REF" --use-api "${@:2}" </dev/null >/dev/null 2>&1 \
    && ok "$1" || { echo "    ✗ $1 failed to deploy" >&2; exit 1; }
}
deploy invoice-pdf  --no-verify-jwt
deploy contract-pdf --no-verify-jwt   # the apporteur's signed contract
deploy notify-email --no-verify-jwt
deploy gdpr-purge   --no-verify-jwt
deploy send-sms     --no-verify-jwt
deploy send-invite                    # called by a signed-in admin: the JWT is checked
deploy auth-email   --no-verify-jwt   # Supabase Auth's send-email hook, signed
deploy send-push    --no-verify-jwt   # inert until the Apple key is set (step 4)

# ------------------------------------------------------- 4. the hooks
say "Hooks between the database and the functions"
secrets="$("$SB" secrets list --project-ref "$REF" -o json </dev/null 2>/dev/null || echo '{}')"
has_secret() { printf '%s' "$secrets" | grep -q "\"name\": *\"$1\""; }

envfile="$(mktemp)"
trap 'rm -f "$envfile"' EXIT
hook() {   # name, secret variable, enabled
  local name="$1" var="$2" enabled="$3" secret
  secret="$(query "select secret from edge_hooks where name = '$name'" \
            | sed -n 's/.*"secret": *"\([0-9a-f]\{64\}\)".*/\1/p' | head -1)"
  [ -n "$secret" ] || secret="$(openssl rand -hex 32)"
  printf '%s=%s\n' "$var" "$secret" >> "$envfile"
  query "insert into edge_hooks (name, url, secret, enabled)
         values ('$name', 'https://$REF.supabase.co/functions/v1/$name', '$secret', $enabled)
         on conflict (name) do update
           set url = excluded.url, secret = excluded.secret, enabled = excluded.enabled,
               updated_at = now()" >/dev/null
  if [ "$enabled" = "true" ]; then ok "$name"; else todo "$name registered, off until its key is set"; fi
}
hook invoice-pdf  INVOICE_PDF_HOOK_SECRET  true
hook contract-pdf CONTRACT_PDF_HOOK_SECRET true
hook notify-email NOTIFY_EMAIL_HOOK_SECRET true
hook gdpr-purge   GDPR_PURGE_HOOK_SECRET   true
# SMS codes become required for signing the moment this hook is on, so it
# waits for the Brevo key: without it no code could be delivered.
if has_secret BREVO_API_KEY; then hook send-sms SEND_SMS_HOOK_SECRET true
else hook send-sms SEND_SMS_HOOK_SECRET false; fi
has_secret SMS_SENDER || printf 'SMS_SENDER=Trinity\n' >> "$envfile"
# Push waits for the Apple key: until then send-push could only answer 503.
if has_secret APNS_KEY_ID && has_secret APNS_TEAM_ID && has_secret APNS_PRIVATE_KEY; then
  hook send-push PUSH_HOOK_SECRET true
else hook send-push PUSH_HOOK_SECRET false; fi
# the app's bundle id (ios/project.yml); production serves TestFlight and the
# App Store, and send-push falls back to the sandbox for Xcode builds by itself
has_secret APNS_TOPIC || printf 'APNS_TOPIC=com.trinityenergie.energycourtage\n' >> "$envfile"
has_secret APNS_ENVIRONMENT || printf 'APNS_ENVIRONMENT=production\n' >> "$envfile"
"$SB" secrets set --project-ref "$REF" --env-file "$envfile" </dev/null >/dev/null
ok "shared secrets stored"

# --------------------------------------------------- 5. auth settings
say "Auth settings (supabase/config.toml)"
if [ "$AUTH" = 0 ]; then
  todo "skipped (--no-auth)"
elif ask "Apply them (sign-up closed, redirect to the app, auth emails through Brevo)?"; then
  # the auth-email hook's secret, given to both sides
  "$SB" secrets set --project-ref "$REF" --env-file <(printf 'SEND_EMAIL_HOOK_SECRET=%s\n' "$SEND_EMAIL_HOOK_SECRET") </dev/null >/dev/null
  if [ -n "$YES" ]; then
    "$SB" config push --project-ref "$REF" --yes </dev/null | grep -E "updated|up to date|message" || true
  else
    "$SB" config push --project-ref "$REF" </dev/tty || todo "config push failed: set them by hand, docs/DEPLOY.md §3"
  fi
fi

# ---------------------------------------------------------- 6. report
say "Still needs a key from you"
missing=0
if has_secret BREVO_API_KEY; then ok "BREVO_API_KEY (SMS and email)"; else todo "BREVO_API_KEY"; missing=1; fi
if has_secret MAIL_FROM; then ok "MAIL_FROM"; else
  todo "MAIL_FROM: a sender verified in Brevo, e.g. \"Trinity Énergie <pierrelouis@trinity-energie.fr>\""; missing=1; fi
if has_secret APNS_KEY_ID && has_secret APNS_TEAM_ID && has_secret APNS_PRIVATE_KEY; then
  ok "APNs key (push notifications)"
else todo "push notifications: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (Apple Developer → Keys), then re-run"; fi
[ "$missing" = 0 ] || echo "    Paste missing keys in the dashboard: Edge Functions → Secrets, then re-run."

say "Done: https://supabase.com/dashboard/project/$REF"
