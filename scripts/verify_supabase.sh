#!/usr/bin/env bash
# Checks a live Supabase project against what this app expects.
#
# Run it after `supabase db push`, and again after each configuration step. It
# only reads; nothing here changes anything.
#
#   scripts/verify_supabase.sh <project-url> <publishable-or-anon-key>
#
# Every check prints why it matters, because a green line nobody understands
# is not worth much.
set -uo pipefail

URL="${1:-}"; KEY="${2:-}"
if [ -z "$URL" ] || [ -z "$KEY" ]; then
  echo "usage: $0 https://<ref>.supabase.co <publishable-or-anon-key>" >&2
  exit 2
fi
URL="${URL%/}"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '        %s\n' "$2"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }

api() {  # api <path>  -> body, with the status on the last line
  curl -sS -m 20 -w $'\n%{http_code}' \
       -H "apikey: $KEY" -H "Authorization: Bearer $KEY" "$URL/rest/v1/$1" 2>&1
}

echo
echo "== 1. The project answers, and the key is accepted =="
body="$(api 'stages?select=key,position&order=position.asc')"
code="$(tail -1 <<<"$body")"; json="$(sed '$d' <<<"$body")"

case "$code" in
  200) ok "the key is accepted and PostgREST is answering" ;;
  401|403)
    bad "the key was refused (HTTP $code)" \
        "$json"
    note "If this is a new-format sb_publishable_ key, try the legacy anon JWT"
    note "from Settings > API > Legacy API keys. Whichever works is the one to"
    note "put in ios/Config.xcconfig."
    echo; echo "$pass passed, $fail failed"; exit 1 ;;
  000)
    bad "could not reach $URL" "network or DNS failure"
    echo; echo "$pass passed, $fail failed"; exit 1 ;;
  *) bad "unexpected HTTP $code" "$json" ;;
esac

echo
echo "== 2. The migrations are applied =="
count="$(grep -o '"key"' <<<"$json" | wc -l | tr -d ' ')"
if [ "$count" = "5" ]; then
  ok "the five pipeline stages are seeded"
else
  bad "expected 5 stages, found $count" \
      "run: supabase db push   (from the repository root)"
fi

for rel in recommendation_feed thread_overview notification_feed \
           legal_documents_for_me payable_invoices member_overview; do
  code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
          -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
          "$URL/rest/v1/$rel?limit=1")"
  # 200 or an RLS-empty result both mean the relation exists; 404 means it does not
  if [ "$code" = "404" ]; then
    bad "$rel is missing" "a migration did not apply; check supabase db push output"
  else
    ok "$rel exists"
  fi
done

echo
echo "== 3. Anonymous access is closed =="
anon="$(curl -sS -m 20 -w $'\n%{http_code}' -H "apikey: $KEY" \
        "$URL/rest/v1/profiles?select=email" 2>&1)"
anon_code="$(tail -1 <<<"$anon")"; anon_body="$(sed '$d' <<<"$anon")"
if [ "$anon_code" = "200" ] && [ "$anon_body" != "[]" ]; then
  bad "an unauthenticated caller can read profiles" \
      "RLS is not doing its job — do NOT put this project in front of users"
else
  ok "an unauthenticated caller reads nothing from profiles"
fi

echo
echo "== 4. The invoice bucket is private =="
buck="$(curl -sS -m 20 -w $'\n%{http_code}' -H "apikey: $KEY" \
        -H "Authorization: Bearer $KEY" "$URL/storage/v1/bucket/invoices" 2>&1)"
bcode="$(tail -1 <<<"$buck")"; bbody="$(sed '$d' <<<"$buck")"
if [ "$bcode" = "200" ] && grep -q '"public":false' <<<"${bbody// /}"; then
  ok "the invoices bucket exists and is private"
elif [ "$bcode" = "200" ]; then
  bad "the invoices bucket is PUBLIC" \
      "every invoice becomes a permanent unauthenticated URL; set public = false"
else
  note "bucket not readable with this key (HTTP $bcode) — check it in the dashboard:"
  note "Storage > invoices must exist and must NOT be public"
fi

echo
echo "== 5. Is anyone able to use it yet? =="
admins="$(curl -sS -m 20 -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
          "$URL/rest/v1/profiles?select=id&role=eq.admin&limit=1")"
note "profiles is behind RLS, so this cannot be answered anonymously."
note "In the SQL editor: select count(*) from profiles where role = 'admin';"
note "If it is 0, nobody can invite anyone — create the first admin by hand"
note "(docs/DEPLOY.md section 3)."

echo
echo "== 6. Legal texts =="
note "In the SQL editor:"
note "  select key, version, active from legal_documents;"
note "All three ship inactive with [PLACEHOLDERS] still in them."
note "Invoicing stays blocked until mandat_facturation is published and signed."

echo
echo "== 7. Push =="
note "In the SQL editor: select count(*) from push_config;"
note "0 means push is inert: in-app notifications work, nothing is sent."
note "That is fine until the APNs key exists (docs/DEPLOY.md section 6)."

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
