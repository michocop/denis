// Energy Courtage — the thing that actually sends a push notification.
//
// Called by the database (call_edge_hook 'send-push') from a trigger on
// `notifications`, with the inserted row already rendered: the same title and
// body the in-app list shows, and the unread count for the icon. It looks up
// that person's devices and posts to APNs (iPhones) and FCM (Android). See
// handler.ts, and the migration 20261005000005_push.sql.
//
// Each platform stands on its own key: without the Apple key iPhones are
// skipped and Android phones still get their pushes, and the other way round.
//
// Deploy (scripts/deploy.sh does all of it, and switches the hook on once
// either key is set; scripts/link_push.sh and scripts/link_fcm.sh set them):
//   supabase functions deploy send-push --no-verify-jwt
//   supabase secrets set APNS_KEY_ID=... APNS_TEAM_ID=... \
//                        APNS_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"
//   FCM_SERVICE_ACCOUNT: the Firebase service-account JSON key, whole
//
// --no-verify-jwt because the caller is the database, not a signed-in user;
// the function is instead protected by the shared secret checked below, so a
// stranger who finds the URL cannot make it send anything.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";
import {
  ApnsConfig,
  ApnsEnvironment,
  dispatch,
  FcmAuth,
  fcmAuth,
  FcmConfig,
  parsePushRow,
  parseServiceAccount,
} from "./handler.ts";

/** APNs wants an ES256 JWT signed with the .p8 key, reused for up to an hour. */
let cachedToken: { value: string; mintedAt: number } | null = null;

async function providerToken(pem: string, keyId: string, teamId: string): Promise<string> {
  const now = Date.now();
  // Apple rejects a token minted less than 20 minutes ago if you ask for a new
  // one too often, and rejects one older than 60 minutes. 45 sits safely inside.
  if (cachedToken && now - cachedToken.mintedAt < 45 * 60 * 1000) {
    return cachedToken.value;
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

/** APNs, if its four secrets are set and the key can be read; null otherwise. */
async function apnsConfig(): Promise<ApnsConfig | null> {
  const pem = Deno.env.get("APNS_PRIVATE_KEY");
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const topic = Deno.env.get("APNS_TOPIC");
  if (!pem || !keyId || !teamId || !topic) return null;
  try {
    return {
      jwt: await providerToken(pem, keyId, teamId),
      topic,
      environment: (Deno.env.get("APNS_ENVIRONMENT") === "sandbox" ? "sandbox" : "production") as ApnsEnvironment,
    };
  } catch (error) {
    // a broken Apple key must not stop the Android phones
    console.error("APNS_PRIVATE_KEY could not be used:", String(error));
    return null;
  }
}

/** One access-token cache per service account, kept while the function is warm. */
let fcmAuthCache: { key: string; auth: FcmAuth } | null = null;

/** FCM, if FCM_SERVICE_ACCOUNT holds a service-account key; null otherwise. */
function fcmConfig(): FcmConfig | null {
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!raw) return null;
  const sa = parseServiceAccount(raw);
  if (!sa) {
    // never the value itself: it is a private key
    console.error("FCM_SERVICE_ACCOUNT is set but is not a service-account JSON key");
    return null;
  }
  const key = `${sa.project_id}/${sa.client_email}/${sa.private_key.length}`;
  if (fcmAuthCache?.key !== key) fcmAuthCache = { key, auth: fcmAuth(sa) };
  return { projectId: sa.project_id, auth: fcmAuthCache.auth };
}

Deno.serve(async (request) => {
  // The database calls this, so the only caller that should get through is one
  // that knows the shared secret. Without this the endpoint would let anyone
  // who found the URL push arbitrary text to every apporteur's lock screen.
  const expected = Deno.env.get("PUSH_HOOK_SECRET");
  if (!expected || request.headers.get("x-hook-secret") !== expected) {
    return new Response("forbidden", { status: 403 });
  }

  const row = parsePushRow(await request.json().catch(() => null));
  if (!row) return new Response("a notification row is required", { status: 400 });

  const apns = await apnsConfig();
  const fcm = fcmConfig();
  if (!apns && !fcm) {
    return Response.json({
      status: "not_configured",
      error: "neither APNs (APNS_PRIVATE_KEY, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC) "
        + "nor FCM (FCM_SERVICE_ACCOUNT) is configured",
    }, { status: 503 });
  }

  // service_role: this runs as the server, and needs to read a token belonging
  // to the recipient rather than to the caller.
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    const outcome = await dispatch(row, {
      async devices(profileId) {
        const { data, error } = await admin
          .from("device_tokens").select("token, platform")
          .eq("profile_id", profileId);
        if (error) throw new Error(error.message);
        return (data ?? []).map((d) => ({ token: d.token as string, platform: d.platform as string }));
      },
      async forget(token) {
        await admin.from("device_tokens").delete().eq("token", token);
      },
      apns,
      fcm,
    });
    // only the outcome is logged: the text may carry a message's first line
    console.log(`push ${row.kind}: ${outcome.sent}/${outcome.results.length} delivered`,
                outcome.results.filter((r) => r.status !== 200), outcome.skipped);
    return Response.json(outcome);
  } catch (error) {
    console.error(`push ${row.kind} failed:`, String(error));
    return Response.json({ status: "error" }, { status: 502 });
  }
});
