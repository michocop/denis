// Energy Courtage — the email side of notifications.
//
// Called by the database (call_edge_hook 'notify-email') for every
// notification is_email_worthy() accepts. See handler.ts, and the migration
// 20261004000003_alerts.sql for the trigger.
//
// Deploy:
//   supabase functions deploy notify-email --no-verify-jwt
//   supabase secrets set NOTIFY_EMAIL_HOOK_SECRET=... RESEND_API_KEY=... MAIL_FROM=...
//   insert into edge_hooks (name, url, secret) values
//     ('notify-email', 'https://<ref>.supabase.co/functions/v1/notify-email', '<same secret>');

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { mailSender } from "../_shared/email.ts";
import { sendNotificationEmail } from "./handler.ts";

Deno.serve(async (request) => {
  const secret = Deno.env.get("NOTIFY_EMAIL_HOOK_SECRET");
  if (!secret || request.headers.get("x-hook-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }
  let id: string | undefined;
  try {
    id = (await request.json()).notification_id;
  } catch { /* handled below */ }
  if (!id || !/^[0-9a-f-]{36}$/i.test(id)) {
    return new Response("notification_id is required", { status: 400 });
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  try {
    return Response.json(await sendNotificationEmail(id, {
      async load(notificationId) {
        const { data, error } = await db.rpc("notification_email", { p_notification_id: notificationId });
        if (error) throw error;
        return data;
      },
      sendMail: mailSender(),
    }));
  } catch (error) {
    console.error(`notification ${id}:`, error);
    return Response.json({ notification_id: id, status: "error", error: String(error) }, { status: 500 });
  }
});
