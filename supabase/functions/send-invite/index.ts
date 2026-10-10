// Energy Courtage — invitations by email.
//
// Deployed WITH JWT verification (the default): only a signed-in user reaches
// it, and create_invite then refuses anyone who is not an admin.
//   supabase functions deploy send-invite
// The account is opened through the admin API and the letter goes out through
// the project's mail provider (Brevo), not through Auth's invitation link.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { mailSender } from "../_shared/email.ts";
import { invitationMail } from "../auth-email/handler.ts";
import { invite } from "./handler.ts";

const CORS = { "Content-Type": "application/json" };

Deno.serve(async (request) => {
  const authorization = request.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL")!;
  const asCaller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const asService = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  let input: Record<string, unknown> = {};
  try { input = await request.json(); } catch { /* validated in invite() */ }

  const result = await invite(input, {
    async createInvite(email, role, autoActivate) {
      const { data, error } = await asCaller.rpc("create_invite", {
        p_email: email, p_role: role, p_auto_activate: autoActivate,
      });
      if (error) throw error;
      return data;
    },
    async openAccount(email) {
      const { error } = await asService.auth.admin.createUser({ email, email_confirm: true });
      // already there: an invitation sent again
      if (error && !/already (been )?registered|already exists/i.test(error.message)) throw error;
    },
    sendInvitation(email) {
      return mailSender()(invitationMail(email));
    },
  });
  return new Response(JSON.stringify(result.body), { status: result.status, headers: CORS });
});
