// Energy Courtage — keeps the promise "Supprimés après 30 jours".
//
// Identity cards and RIBs are kept thirty days, then deleted: the file through
// the Storage API (deleting a row of storage.objects in SQL would leave the
// file itself behind), and only then the justificatifs row, so a file can
// never outlive the record that says it exists.
//
// Deploy and schedule (daily, 03:00):
//   supabase functions deploy purge-justificatifs --no-verify-jwt
//   supabase secrets set PURGE_HOOK_SECRET="$(openssl rand -hex 32)"
//   then in the SQL editor (pg_cron and pg_net are enabled on Supabase):
//   select cron.schedule('purge-justificatifs', '0 3 * * *', $$
//     select net.http_post(
//       url     := 'https://<ref>.supabase.co/functions/v1/purge-justificatifs',
//       headers := jsonb_build_object('x-hook-secret', '<PURGE_HOOK_SECRET>'));
//   $$);

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

Deno.serve(async (request) => {
  const expected = Deno.env.get("PURGE_HOOK_SECRET");
  if (!expected || request.headers.get("x-hook-secret") !== expected) {
    return new Response("forbidden", { status: 403 });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: expired, error } = await admin.rpc("expired_justificatifs");
  if (error) return new Response(error.message, { status: 500 });
  if (!expired?.length) return Response.json({ deleted: 0 });

  const rows = expired as { id: string; storage_path: string }[];
  const { error: removeError } = await admin.storage
    .from("justificatifs")
    .remove(rows.map((r) => r.storage_path));
  if (removeError) {
    // rows stay, so tomorrow's run tries again
    return new Response(removeError.message, { status: 502 });
  }

  let forgotten = 0;
  for (const row of rows) {
    const { error: forgetError } = await admin.rpc("forget_justificatif", { p_id: row.id });
    if (!forgetError) forgotten++;
  }
  return Response.json({ deleted: forgotten });
});
