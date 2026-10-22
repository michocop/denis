#!/usr/bin/env bash
# Switches on Android push notifications, from the Firebase key file, in one go.
#
#   scripts/link_fcm.sh ~/Downloads/trinity-energie-firebase-adminsdk-xxxxx.json [deploy.sh options]
#
# The key: console.firebase.google.com → the project → ⚙ Project settings →
# Service accounts → Firebase Admin SDK → "Generate new private key". Google
# lets you download each key once; keep the file somewhere safe, out of git.
#
# What it does:
#   1. checks the file is a service-account key (and, if android/firebase.properties
#      exists, that it is for the same Firebase project as the app)
#   2. stores it as the function secret FCM_SERVICE_ACCOUNT -- through a file
#      descriptor, never on the command line or on screen
#   3. re-runs scripts/deploy.sh, which switches the send-push hook on now that
#      a key is set (any options after the file are passed to it, e.g. --yes)
#
# Re-running it with a new key replaces the old one. iPhone push is separate
# (scripts/link_push.sh); either works without the other.
set -euo pipefail

KEY="${1:-}"
if [ -z "$KEY" ] || [ ! -f "$KEY" ]; then
  echo "usage: scripts/link_fcm.sh path/to/service-account.json [deploy.sh options]" >&2
  exit 2
fi
shift
KEY="$(cd "$(dirname "$KEY")" && pwd)/$(basename "$KEY")"

cd "$(dirname "$0")/.."
command -v python3 >/dev/null 2>&1 || { echo "python3 is needed to read the key file (xcode-select --install)" >&2; exit 1; }

# The key on one line, checked. Only the project id is ever printed.
# shellcheck disable=SC2016
read_key='
import json, sys
try:
    sa = json.load(open(sys.argv[1]))
except Exception:
    sys.exit("not a JSON file")
if sa.get("type") != "service_account" or not all(sa.get(k) for k in ("project_id", "client_email", "private_key")):
    sys.exit("not a Firebase service-account key (expected type, project_id, client_email, private_key)")
if "PRIVATE KEY" not in sa["private_key"]:
    sys.exit("its private_key is not a PEM key")
if sys.argv[2] == "project":
    print(sa["project_id"])
else:
    line = json.dumps(sa, separators=(",", ":"))
    # single-quoted in the env file, so nothing in it is expanded
    if "\x27" in line:
        sys.exit("unexpected quote in the key file")
    print("FCM_SERVICE_ACCOUNT=\x27" + line + "\x27")
'
PROJECT="$(python3 -I -c "$read_key" "$KEY" project)" || exit 2

APP_PROJECT="$(sed -n 's/^FIREBASE_PROJECT_ID=//p' android/firebase.properties 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$APP_PROJECT" ] && [ "$APP_PROJECT" != "$PROJECT" ]; then
  echo "This key is for Firebase project \"$PROJECT\", but android/firebase.properties says \"$APP_PROJECT\"." >&2
  echo "Tokens from the app would be refused (SENDER_ID_MISMATCH). Use the key of the app's project." >&2
  exit 2
fi

export SEND_EMAIL_HOOK_SECRET="$(sed -n 's/^SEND_EMAIL_HOOK_SECRET=//p' supabase/.env 2>/dev/null || true)"
SB="$(command -v supabase || echo "$PWD/.devtools/supabase/supabase")"
[ -x "$SB" ] || { echo "No Supabase CLI: run scripts/deploy.sh once first, it installs it." >&2; exit 1; }
REF="$(sed -n 's/^project_id = "\(.*\)"/\1/p' supabase/config.toml)"

echo "==> Storing the Firebase key (project $PROJECT)"
# through a file descriptor, so the key never appears in the process list
"$SB" secrets set --project-ref "$REF" --env-file <(python3 -I -c "$read_key" "$KEY" env) </dev/null >/dev/null

echo "==> Re-running the deploy, which switches push on"
scripts/deploy.sh "$@"

echo
echo "Done. Each Android phone that allowed notifications gets them from the next event on"
echo "(a new recommendation, a stage, an invoice to sign, a message)."
