// Energy Courtage — the thing that actually sends a signature code.
//
// The database generates the code, keeps only its hash, and posts the code
// here (request_signature_otp, see the migration). This forwards it to the
// SMS provider and nothing else: it stores nothing and logs no code.
//
// Deploy:
//   supabase functions deploy send-sms --no-verify-jwt
//   supabase secrets set SMS_HOOK_SECRET=... SMS_PROVIDER=twilio \
//                        TWILIO_ACCOUNT_SID=... TWILIO_AUTH_TOKEN=... TWILIO_FROM=TRINITY
//   then, in the SQL editor, switch the requirement on:
//   insert into sms_config (function_url, hook_secret)
//   values ('https://<ref>.supabase.co/functions/v1/send-sms', '<same SMS_HOOK_SECRET>');
//
// --no-verify-jwt because the caller is the database, not a signed-in user;
// the shared secret below is what keeps a stranger who finds the URL from
// sending texts on the company's bill.

import { buildRequest, type Message } from "./providers.ts";

Deno.serve(async (request) => {
  const expected = Deno.env.get("SMS_HOOK_SECRET");
  if (!expected || request.headers.get("x-hook-secret") !== expected) {
    return new Response("forbidden", { status: 403 });
  }

  let message: Message;
  try {
    message = await request.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }

  let outgoing;
  try {
    outgoing = buildRequest(Deno.env.toObject(), message);
  } catch (error) {
    console.error("send-sms:", (error as Error).message);
    return new Response((error as Error).message, { status: 400 });
  }

  const response = await fetch(outgoing.url, outgoing.init);
  if (!response.ok) {
    // the provider's answer, never the code: it would end up in the logs
    console.error("send-sms: provider refused", response.status, await response.text());
    return new Response("provider refused", { status: 502 });
  }
  return Response.json({ sent: true, to: message.to.slice(0, 4) + "…" + message.to.slice(-2) });
});
