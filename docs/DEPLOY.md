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
