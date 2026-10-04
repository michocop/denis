// Energy Courtage — the RGPD retention sweep. Called on the 1st of each month
// by pg_cron through call_edge_hook('gdpr-purge').
//   supabase functions deploy gdpr-purge --no-verify-jwt
//   supabase secrets set GDPR_PURGE_HOOK_SECRET=...
//   insert into edge_hooks (name, url, secret) values
//     ('gdpr-purge', 'https://<ref>.supabase.co/functions/v1/gdpr-purge', '<same secret>');

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { purge } from "./handler.ts";

Deno.serve(async (request) => {
  const secret = Deno.env.get("GDPR_PURGE_HOOK_SECRET");
  if (!secret || request.headers.get("x-hook-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  try {
    return Response.json(await purge({
      async purge() {
        const { data, error } = await db.rpc("purge_stale_leads");
        if (error) throw error;
        return data;
      },
      async removeFiles(paths) {
        const { error } = await db.storage.from("documents").remove(paths);
        if (error) throw error;
      },
    }));
  } catch (error) {
    console.error("gdpr purge:", error);
    return Response.json({ status: "error", error: String(error) }, { status: 500 });
  }
});
