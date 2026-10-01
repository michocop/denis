# Standing the backend up on Supabase's free tier

Everything the app needs — Postgres, auth, storage — is inside Supabase's free
plan. There is no server to run and nothing to deploy to Vercel: the iOS app
talks to Supabase directly, and the rules that would otherwise live in a
backend live in the database as RLS policies and RPCs.

The project must be created under **the client's own account**, not a
developer's. It holds their apporteurs' personal data and their invoices, and
moving a project between accounts later means a migration, not a click.

---

## 1. Create the project

1. Sign up at <https://supabase.com> and create a new project.
2. Region: **Europe (Frankfurt or Paris)**. The data is personal data of
   people in France; keeping it in the EU is the simple answer to where it
   lives, and avoids a transfer question nobody wants to argue about.
3. Save the database password somewhere real. It is shown once.

Free plan limits worth knowing: 500 MB of database, 1 GB of file storage, and
the project is **paused after a week with no activity**. A paused project
answers every request with an error until someone opens the dashboard, so the
free tier is right for a pilot and wrong for a launch. Moving to Pro is a
button, not a migration.

## 2. Apply the schema

```bash
brew install supabase/tap/supabase          # or npm i -g supabase
supabase login
supabase link --project-ref <your-project-ref>
supabase db push                            # applies supabase/migrations/ in order
```

**Run these from the repository root.** `supabase/config.toml` is committed, so
`supabase init` is neither needed nor wanted — run it elsewhere and `db push`
finds no migrations and cheerfully applies nothing.

Then check the result in one command:

```bash
scripts/verify_supabase.sh https://<ref>.supabase.co <publishable-key>
```

`db push` applies only `supabase/migrations/`. Never apply
`supabase/local/00_auth_shim.sql` — it fakes `auth.users` and `auth.uid()` for
the offline test harness, and a real project already has them.

One migration creates a private `invoices` storage bucket and its policies. If
`supabase db push` refuses the `storage.objects` policies for lack of
ownership, run that one file from the SQL editor in the dashboard, which
executes as the owning role.

### Verify

```sql
select count(*) from stages;              -- 5
select count(*) from pg_policies where schemaname = 'public';
select id, public from storage.buckets;   -- invoices, false
```

`public` must be **false** on the invoices bucket. A public bucket turns every
invoice into a permanent unauthenticated URL.

## 3. Auth settings

In **Authentication → Providers**:

- Email/password: **on**.
- "Confirm email": **on**. Sign-up is invitation-based anyway, but an
  unverified address is one nobody can send an invoice to.
- Disable every other provider. There is no reason for this app to accept a
  Google or GitHub identity.

In **Authentication → URL configuration**, set the site URL to the app's
custom scheme so password-reset links come back into the app.

There is no open registration: `redeem_invite` turns an auth account into a
profile, and an account with no profile reaches no data at all. The first
administrator therefore has to be made by hand:

```sql
-- after signing up through the app with the client's own address
insert into profiles (id, role, status, first_name, last_name, email)
select id, 'admin', 'active', 'Pierre-Louis', 'Tettamanti', email
  from auth.users where email = 'the-address-you-signed-up-with';
```

From then on, invitations are created from the app.

## 4. Point the app at it

The two values are in **Project Settings → API**:

- Project URL → `SUPABASE_URL`
- `anon` **public** key → `SUPABASE_ANON_KEY`

The anon key is meant to ship inside the app; it grants nothing on its own,
because every table is behind RLS. The **service_role** key is the opposite:
it bypasses RLS entirely. It must never appear in the app, in the repository,
in CI logs, or in a chat message.

```bash
cp ios/Config.example.xcconfig ios/Config.xcconfig   # git-ignored
# fill in the two values, then build
```

Without them the app falls back to demo data rather than showing a sign-in
form with nothing behind it.

## 5. Backups

The free plan keeps no backups. Until the project moves to Pro, take one:

```bash
supabase db dump -f backup-$(date +%F).sql
```

Invoices must be kept ten years (art. 242 nonies A ann. II CGI). A dump on
somebody's laptop does not meet that; the retained PDFs live in the storage
bucket and need their own copy.

## What is not here

**Push notifications.** The client side is finished — the device token is
registered into `device_tokens` on launch — but nothing sends. That needs an
APNs key from the Apple Developer account and something holding it: a Supabase
Edge Function triggered on insert into `notifications` is the natural place.
Until then, notifications are in-app and on-device only, which covers
reminders but not "a new message arrived while the app was closed".

**Email.** Supabase's built-in SMTP is rate-limited to a handful of messages
an hour and is not for production. Connecting a real sender (Resend, Postmark,
SES) is a settings page, and is needed before the first real invitation goes
out.

---

## 6. Push notifications

The client side is finished and the sender now exists
(`supabase/functions/send-push`). What it needs is a key only an Apple
Developer account can issue, so this step waits on §Apple below.

### The APNs key

1. Apple Developer → Certificates, Identifiers & Profiles → **Keys** → **+**
2. Name it, tick **Apple Push Notifications service (APNs)**, register.
3. Download the `.p8` **once** — Apple does not let you download it again.
   Note the **Key ID** and your **Team ID**.
4. In the app's identifier, enable the **Push Notifications** capability. The
   app only calls `registerForRemoteNotifications()` when the entitlement is
   present, so nothing happens until this is done and nothing breaks either.

### Deploy the sender

```bash
supabase functions deploy send-push --no-verify-jwt

supabase secrets set \
  APNS_KEY_ID=ABC123DEFG \
  APNS_TEAM_ID=1234567890 \
  APNS_TOPIC=com.trinityenergie.energycourtage \
  APNS_ENVIRONMENT=production \
  PUSH_HOOK_SECRET="$(openssl rand -hex 32)" \
  APNS_PRIVATE_KEY="$(cat AuthKey_ABC123DEFG.p8)"
```

`--no-verify-jwt` because the caller is the database, not a signed-in user.
The function is protected by `PUSH_HOOK_SECRET` instead — without that check
anyone who found the URL could push arbitrary text to every apporteur's lock
screen.

`APNS_ENVIRONMENT=sandbox` for builds installed from Xcode; TestFlight and the
App Store use `production`. A token minted in one environment is rejected by
the other, which is the usual cause of "it worked on my phone and not in
TestFlight".

### Point the database at it

```sql
insert into push_config (function_url, hook_secret)
values ('https://<project-ref>.supabase.co/functions/v1/send-push',
        '<the same PUSH_HOOK_SECRET>');
```

`push_config` has **no RLS policy for `authenticated`**, on purpose: the secret
in it would let its holder push anything to anyone, and no screen needs it.
Only the trigger reads it, as definer.

Until that row exists the trigger is inert — notifications still appear in the
app, nothing is sent, and nothing errors. That is the state the project ships
in, and it is a tested path rather than an accident.

To stop sending without touching anything else: `update push_config set
enabled = false;`

---

## 7. The legal texts

They live in the `legal_documents` table, not in the app bundle, so correcting
a clause does not need an App Store release.

Three are seeded **inactive**, each still carrying `[PLACEHOLDERS]`:

| key | what |
|---|---|
| `mandat_facturation` | the self-billing mandate — **invoicing is refused without it** |
| `cgu` | terms of use |
| `confidentialite` | privacy policy |

To publish one:

1. Fill every `[PLACEHOLDER]` — company name, SIREN, address, notice periods.
2. **Have a lawyer read it.** These are drafts written to save a professional
   time, not to replace one.
3. ```sql
   update legal_documents
      set body = '<the reviewed text>', active = true
    where key = 'mandat_facturation' and version = '2026-09-1';
   ```

The publish trigger **refuses** a document that still contains a placeholder,
so nobody can be asked to sign a contract with `[RAISON SOCIALE]` where the
company's name belongs. It also derives the SHA-256 itself — a digest supplied
alongside the text it describes proves nothing.

### Revising one

Insert a **new version** and activate it; never edit a published one. The old
row stays because somebody signed it, and their acceptance has to remain
readable. Everyone is then asked to accept the new version, which is the whole
reason it is versioned:

```sql
update legal_documents set active = false where key = 'mandat_facturation';
insert into legal_documents (key, version, title, body, sha256, active)
values ('mandat_facturation', '2026-10-1', 'Mandat de facturation', '<text>', '', true);
```

### What is recorded

`legal_acceptances` keeps one row per person per version: the version, the
digest of the exact bytes they were shown, their name, the time, and
optionally IP and user agent. The app hashes what it rendered and the server
refuses a mismatch — the same rule invoice signatures follow, so consent can
only ever attach to the text that was actually displayed.

---

## 8. Email

Supabase's built-in SMTP is rate-limited to a handful of messages an hour and
is explicitly not for production. Before the first real invitation goes out,
connect a sender under **Project Settings → Authentication → SMTP**:

- Resend, Postmark or SES all work; any of them needs the sending domain's
  SPF and DKIM records set, or the mail lands in spam.
- Set the sender name to the client's, not the developer's.
- Customise the templates under **Authentication → Email Templates**: the
  defaults say "Supabase" to someone who has never heard of it.

Only two are reachable in this app — **Confirm signup** and **Reset password**
— because sign-up is invitation-based and the invitation code is read out by
an admin rather than emailed.
