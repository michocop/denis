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

### The company's identity on invoices

Every invoice names the company as the customer, by its legal identity, and
**no invoice can be issued until this row exists**. Fill it with the real
details from the Kbis -- they are copied onto each invoice when it is issued,
so a mistake here is printed on documents kept for ten years:

```sql
insert into billing_settings (legal_name, legal_form, share_capital, siren, rcs_city,
                              vat_number, address, postal_code, city,
                              payment_term_days)
values ('Trinity Énergie', 'SAS', '10 000 €', '123456789', 'Lille',
        'FR00123456789', '1 rue …', '59310', 'Aix-en-Pévèle', 30);
```

`payment_term_days` is the due date printed on each invoice (30 by default,
60 at most under art. L441-10). Changing the row later affects only invoices
issued afterwards.

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

Everything is built and deployed: the app registers its device token, the
database renders each notification and hands it to `send-push`, and
`send-push` posts it to Apple. What is missing is a key only an Apple
Developer account can issue, so this step waits on §Apple below. Until then
notifications appear in the app and important ones go by email; nothing is
pushed, and nothing errors.

What is pushed: a lead advancing or lost, a commission earned, an invoice to
sign, countersigned or paid, a message, an account approved; and, for admins,
a new lead, a member to approve, an invoice to countersign, a document added.
Not reminders: the phone that set one already rings at that minute.
The icon badge carries the unread count, so it is right before the app opens.

### The APNs key

1. Apple Developer → Certificates, Identifiers & Profiles → **Keys** → **+**
2. Name it, tick **Apple Push Notifications service (APNs)**, register.
3. Download the `.p8` **once** — Apple does not let you download it again.
   Note the **Key ID** and your **Team ID**.
4. In the app's identifier, enable the **Push Notifications** capability. The
   app only calls `registerForRemoteNotifications()` when the entitlement is
   present, so nothing happens until this is done and nothing breaks either.

### Switch it on

```bash
supabase secrets set --project-ref <ref> \
  APNS_KEY_ID=ABC123DEFG \
  APNS_TEAM_ID=1234567890 \
  APNS_PRIVATE_KEY="$(cat AuthKey_ABC123DEFG.p8)"
scripts/deploy.sh
```

`deploy.sh` sees the three keys and switches the `send-push` hook on, with a
fresh `PUSH_HOOK_SECRET` given to both the function and `edge_hooks`. It also
sets `APNS_TOPIC` to the bundle id and `APNS_ENVIRONMENT=production`, which is
what TestFlight and the App Store use. A build installed from Xcode has a
sandbox token; `send-push` notices Apple's `BadDeviceToken` and retries it on
the sandbox, so one key serves both without changing anything.

A token is dropped only when Apple says it no longer reaches anyone (410, or
unknown in both environments). A mistake on our side, such as a wrong topic,
is reported in the function's logs and costs nobody their device.

To stop sending without touching anything else:
`update edge_hooks set enabled = false where name = 'send-push';`

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

## 9. SMS codes (Brevo)

Once this is set up, an apporteur signs an invoice only with a six-digit code
sent by SMS to a mobile number they verified in the app (Profil → Vérifier mon
mobile). The signature records that it was confirmed, and to which masked
number, and the PDF prints it. Until the `send-sms` hook below exists, signing
works without a code, so the order of these steps does not matter.

Brevo is the provider: about €0.045 per SMS to France, bought in packs (from
100 SMS) that do not expire, with no subscription.

1. Create an account at brevo.com and buy SMS credits
   (**Campaigns → SMS → Buy credits**, or the credits page in the account menu).
2. Create an API key: **SMTP & API → API Keys → Generate a new API key**.
3. Deploy the function and give it the key:

```sh
supabase functions deploy send-sms --no-verify-jwt
supabase secrets set \
  SEND_SMS_HOOK_SECRET="$(openssl rand -hex 32)" \
  BREVO_API_KEY=xkeysib-... \
  SMS_SENDER=Trinity
```

   `SMS_SENDER` is the name shown as the sender: letters and digits only, 11 at
   most. French operators accept an alphanumeric sender for transactional SMS.

4. Point the database at it, with the same secret, in the SQL editor:

```sql
insert into edge_hooks (name, url, secret) values
  ('send-sms', 'https://<project-ref>.supabase.co/functions/v1/send-sms', '<SEND_SMS_HOOK_SECRET>');
```

From that moment signatures need a code. To turn it off again:
`update edge_hooks set enabled = false where name = 'send-sms';`

What the database enforces: a code expires after 10 minutes, allows 5 tries,
works once, and is bound to one person, one purpose and (for a signature) one
invoice. It is stored only as a hash. A person can ask for one code every 30
seconds and six an hour. Changing the phone number in the profile removes the
verification. Failed sends show in **Edge Functions → send-sms → Logs** (the
number is masked there, and the code never appears).

## 10. Emails (Brevo)

Every email goes through the same Brevo account as the SMS (free plan: 300 a
day), with the same API key:

- invoice PDFs and notifications, from the `invoice-pdf` and `notify-email`
  functions;
- Auth's own emails (invitations, password resets), through the `auth-email`
  function, which Supabase calls as its "send email" hook. Supabase's shared
  SMTP is not used: it only reaches the project's own team.

The sender is the `MAIL_FROM` secret, `Trinity Énergie <pierrelouis@trinity-energie.fr>`.
Brevo only sends from a verified sender: **Brevo → Senders → Add sender**, then
the code Brevo emails to that address. For the best deliverability, also
authenticate the domain (**Senders → Domains → trinity-energie.fr**, three DNS
records at the domain's registrar).

`scripts/deploy.sh` deploys the function and keeps the hook's signing secret in
`supabase/.env` (git-ignored) and on both sides.

## 11. Backups

`scripts/backup.sh --install` (done on the developer's Mac) backs the project up
every night at 02:30: each table as JSON through the Supabase API, the
`invoices` and `documents` files, in one AES-256 archive kept 30 days in iCloud
Drive → "Trinity Énergie — sauvegardes". No database password is stored; the
archive passphrase is in the Keychain:

```sh
security find-generic-password -s trinity-energie-backup -w
```

Copy it into the company's password manager. Restore with
`scripts/restore.sh <archive> [--into <database-url>]`. The nightly run is also
activity on the project, so the free plan never pauses it. On the Pro plan,
Supabase's own daily backups come on top.
