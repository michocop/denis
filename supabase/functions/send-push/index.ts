// Energy Courtage — the thing that actually sends a push notification.
//
// The client side has been finished for a while: device tokens are registered
// into device_tokens, notifications rows carry a title and body rendered in
// SQL, and the app clears the token on sign-out. Nothing sent them. This is
// what sends them.
//
// It is invoked by a trigger on `notifications` (see the migration), receives
// the inserted row, looks up that person's devices and posts to APNs.
//
// Deploy:
//   supabase functions deploy send-push --no-verify-jwt
//   supabase secrets set APNS_KEY_ID=... APNS_TEAM_ID=... APNS_TOPIC=... \
//                        APNS_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)" \
//                        APNS_ENVIRONMENT=production
//
// --no-verify-jwt because the caller is the database, not a signed-in user;
// the function is instead protected by the shared secret checked below, so a
// stranger who finds the URL cannot make it send anything.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

/** APNs wants an ES256 JWT signed with the .p8 key, reused for up to an hour. */
let cachedToken: { value: string; mintedAt: number } | null = null;

async function providerToken(): Promise<string> {
  const now = Date.now();
  // Apple rejects a token minted less than 20 minutes ago if you ask for a new
  // one too often, and rejects one older than 60 minutes. 45 sits safely inside.
  if (cachedToken && now - cachedToken.mintedAt < 45 * 60 * 1000) {
    return cachedToken.value;
  }

  const pem = Deno.env.get("APNS_PRIVATE_KEY");
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  if (!pem || !keyId || !teamId) {
    throw new Error("APNs is not configured: APNS_PRIVATE_KEY, APNS_KEY_ID and APNS_TEAM_ID are required");
  }

  const der = Uint8Array.from(
    atob(pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s/g, "")),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const value = await create(
    { alg: "ES256", kid: keyId },
    { iss: teamId, iat: getNumericDate(0) },
    key,
  );
  cachedToken = { value, mintedAt: now };
  return value;
}

interface NotificationRow {
  id: string;
  profile_id: string;
  kind: string;
  title: string;
  body: string;
  thread_id: string | null;
  recommendation_id: string | null;
  invoice_id: string | null;
}

Deno.serve(async (request) => {
  // The database calls this, so the only caller that should get through is one
  // that knows the shared secret. Without this the endpoint would let anyone
  // who found the URL push arbitrary text to every apporteur's lock screen.
  const expected = Deno.env.get("PUSH_HOOK_SECRET");
  if (!expected || request.headers.get("x-hook-secret") !== expected) {
    return new Response("forbidden", { status: 403 });
  }

  let row: NotificationRow;
  try {
    row = (await request.json()).record;
  } catch {
    return new Response("bad request", { status: 400 });
  }
  if (!row?.profile_id) return new Response("no recipient", { status: 400 });

  // service_role: this runs as the server, and needs to read a token belonging
  // to the recipient rather than to the caller.
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: devices, error } = await admin
    .from("device_tokens")
    .select("token")
    .eq("profile_id", row.profile_id)
    .eq("platform", "ios");

  if (error) return new Response(error.message, { status: 500 });
  if (!devices?.length) return new Response("no devices", { status: 200 });

  const host = APNS_HOSTS[(Deno.env.get("APNS_ENVIRONMENT") ?? "production") as keyof typeof APNS_HOSTS];
  const topic = Deno.env.get("APNS_TOPIC");
  const jwt = await providerToken();

  const payload = JSON.stringify({
    aps: {
      alert: { title: row.title, body: row.body },
      sound: "default",
      "thread-id": row.thread_id ?? row.kind,
    },
    // so a tap can open the thing the notification is about
    kind: row.kind,
    thread_id: row.thread_id,
    recommendation_id: row.recommendation_id,
    invoice_id: row.invoice_id,
  });

  const results = await Promise.all(devices.map(async ({ token }) => {
    const response = await fetch(`${host}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": topic!,
        "apns-push-type": "alert",
        "apns-priority": "10",
        // APNs deduplicates on this, so a retry cannot double-notify
        "apns-collapse-id": row.id.slice(0, 64),
      },
      body: payload,
    });

    // 410 means the app was deleted from that device. Apple asks that the
    // token be dropped; leaving it would push to nobody forever.
    if (response.status === 410 || response.status === 400) {
      await admin.from("device_tokens").delete().eq("token", token);
    }
    return { token: token.slice(0, 8), status: response.status };
  }));

  return Response.json({ sent: results.length, results });
});
