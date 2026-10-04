// Energy Courtage — invitations by email.
//
// Deployed WITH JWT verification (the default): only a signed-in user reaches
// it, and create_invite then refuses anyone who is not an admin.
//   supabase functions deploy send-invite
// The email itself is Supabase Auth's invitation template; set its link to
// {{ .ConfirmationURL }} and its sender to the client's domain (Resend SMTP).

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
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
    async sendInvitation(email, redirectTo) {
      const { error } = await asService.auth.admin.inviteUserByEmail(email, { redirectTo });
      if (error) throw error;
    },
  });
  return new Response(JSON.stringify(result.body), { status: result.status, headers: CORS });
});
