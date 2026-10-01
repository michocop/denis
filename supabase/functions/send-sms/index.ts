// Energy Courtage — the thing that actually sends a signature code.
//
// The database generates the code, keeps only its hash, and posts the code
// here with the channel to use (request_signature_otp, see the migrations).
// This forwards it to the provider and nothing else: it stores nothing and
// logs no code.
//
// SMS is the channel in use. WhatsApp can be switched on in sms_config; when
// it is, and WhatsApp refuses a number (no WhatsApp account, template not
// approved yet), the same code goes out by SMS instead.
//
// Deploy:
//   supabase functions deploy send-sms --no-verify-jwt
//   supabase secrets set SMS_HOOK_SECRET=... \
//     SMS_PROVIDER=brevo BREVO_API_KEY=... BREVO_SENDER=TRINITY
//   (WhatsApp, only if switched on later: TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN,
//    TWILIO_WHATSAPP_FROM, TWILIO_WHATSAPP_CONTENT_SID)
//   then, in the SQL editor, switch the requirement on:
//   insert into sms_config (function_url, hook_secret)
//   values ('https://<ref>.supabase.co/functions/v1/send-sms', '<same SMS_HOOK_SECRET>');
//
// --no-verify-jwt because the caller is the database, not a signed-in user;
// the shared secret below is what keeps a stranger who finds the URL from
// sending messages on the company's bill.

import { buildRequest, channelOf, smsFallback, type Message } from "./providers.ts";

async function send(url: string, init: RequestInit): Promise<{ ok: boolean; status: number; text: string }> {
  try {
    const response = await fetch(url, init);
    return { ok: response.ok, status: response.status, text: response.ok ? "" : await response.text() };
  } catch (error) {
    return { ok: false, status: 0, text: (error as Error).message };
  }
}

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

  const env = Deno.env.toObject();
  const channel = channelOf(env, message);
  const masked = message.to.slice(0, 4) + "…" + message.to.slice(-2);

  let first: { ok: boolean; status: number; text: string };
  try {
    const outgoing = buildRequest(env, message);
    first = await send(outgoing.url, outgoing.init);
  } catch (error) {
    first = { ok: false, status: 0, text: (error as Error).message };
  }
  if (first.ok) return Response.json({ sent: true, channel, to: masked });

  // the provider's answer, never the code: it would end up in the logs
  console.error(`send-sms: ${channel} refused`, first.status, first.text);

  if (channel === "whatsapp") {
    const fallback = smsFallback(env, message);
    if (fallback) {
      const second = await send(fallback.url, fallback.init);
      if (second.ok) return Response.json({ sent: true, channel: "sms", fallback: true, to: masked });
      console.error("send-sms: SMS fallback refused", second.status, second.text);
    }
  }
  return new Response("provider refused", { status: 502 });
});
