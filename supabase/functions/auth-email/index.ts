// Energy Courtage — Supabase Auth's emails, in the brand's letterhead, through Brevo.
//
// Wired in supabase/config.toml ([auth.hook.send_email]) and deployed by
// scripts/deploy.sh. Supabase signs each call (Standard Webhooks) with
// SEND_EMAIL_HOOK_SECRET; anything unsigned is refused.

import { Webhook } from "npm:standardwebhooks@1.0.0";
import { mailSender } from "../_shared/email.ts";
import { authMail, HookPayload } from "./handler.ts";

Deno.serve(async (request) => {
  const secret = (Deno.env.get("SEND_EMAIL_HOOK_SECRET") ?? "").replace(/^v1,whsec_/, "");
  const body = await request.text();
  let payload: HookPayload;
  try {
    payload = new Webhook(secret).verify(body, Object.fromEntries(request.headers)) as HookPayload;
  } catch {
    return Response.json({ error: { http_code: 401, message: "invalid signature" } }, { status: 401 });
  }
  try {
    const status = await mailSender()(authMail(payload, Deno.env.get("SUPABASE_URL")!));
    if (status !== "sent") throw new Error("no email provider configured (BREVO_API_KEY and MAIL_FROM)");
    return Response.json({});
  } catch (error) {
    console.error(`auth email (${payload.email_data.email_action_type}) failed:`, String(error));
    return Response.json({ error: { http_code: 500, message: String(error) } }, { status: 500 });
  }
});
