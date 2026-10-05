// Energy Courtage — SMS codes, sent through Brevo.
//
// Called by the database (call_edge_hook 'send-sms') from request_sms_code():
// to verify a mobile number, and before an apporteur signs an invoice. Once
// the edge_hooks row exists, signing requires the code. See handler.ts, and
// the migration 20261005000002_sms.sql.
//
// Deploy:
//   supabase functions deploy send-sms --no-verify-jwt
//   supabase secrets set SEND_SMS_HOOK_SECRET=... BREVO_API_KEY=... SMS_SENDER=Trinity
//   insert into edge_hooks (name, url, secret) values
//     ('send-sms', 'https://<ref>.supabase.co/functions/v1/send-sms', '<same secret>');

import { maskForLog, parseSms, sendSms } from "./handler.ts";

Deno.serve(async (request) => {
  const secret = Deno.env.get("SEND_SMS_HOOK_SECRET");
  if (!secret || request.headers.get("x-hook-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }
  const sms = parseSms(await request.json().catch(() => null));
  if (!sms) return new Response("a phone number in international form and a text are required", { status: 400 });

  try {
    const outcome = await sendSms(sms, {
      apiKey: Deno.env.get("BREVO_API_KEY"),
      sender: Deno.env.get("SMS_SENDER"),
    });
    // the text carries the code: only the outcome and a masked number are logged
    console.log(`sms to ${maskForLog(sms.to)}: ${outcome.status}`,
                outcome.status === "rejected" ? outcome.error : "");
    return Response.json(outcome, { status: outcome.status === "sent" ? 200 : 502 });
  } catch (error) {
    console.error(`sms to ${maskForLog(sms.to)} failed:`, String(error));
    return Response.json({ status: "error" }, { status: 502 });
  }
});
