import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  apnsPayload, deliver, Device, dispatch, DispatchDeps, FcmAuth, fcmAuth, fcmMessage, fcmTokenGone, parsePushRow,
  parseServiceAccount, PushRow, ServiceAccount, signServiceAccountJwt,
} from "./handler.ts";

const row: PushRow = {
  id: "0b9f6c1e-2d4a-4f7b-9a51-6f0c2e8d7a10",
  profile_id: "11111111-1111-1111-1111-111111111111",
  kind: "invoice_ready",
  title: "Facture à signer",
  body: "Facture FA-2026-0001 — 300,00 €",
  thread_id: null,
  recommendation_id: null,
  invoice_id: "5d1c0a2e-7b3f-4e29-8c64-2a9f1e0b7d33",
  badge: 3,
};

/** APNs, answering each host and token from a table; anything else is a 200. */
function fakeApple(answers: Record<string, { status: number; reason?: string }> = {}) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetch = ((url: string, init: RequestInit) => {
    calls.push({ url, init });
    const answer = Object.entries(answers).find(([key]) => url.includes(key))?.[1] ?? { status: 200 };
    return Promise.resolve(new Response(answer.reason ? JSON.stringify({ reason: answer.reason }) : null,
                                        { status: answer.status }));
  }) as unknown as typeof globalThis.fetch;
  return { calls, fetch };
}

function deps(tokens: string[], apple: ReturnType<typeof fakeApple>) {
  const forgotten: string[] = [];
  return {
    forgotten,
    deps: {
      tokens: () => Promise.resolve(tokens),
      forget: (token: string) => { forgotten.push(token); return Promise.resolve(); },
      jwt: "provider-jwt",
      topic: "com.trinityenergie.energycourtage",
      environment: "production" as const,
      fetch: apple.fetch,
    },
  };
}

Deno.test("the lock screen shows what the list shows, with the badge and where a tap leads", () => {
  const p = JSON.parse(apnsPayload(row));
  assertEquals(p.aps.alert, { title: "Facture à signer", body: "Facture FA-2026-0001 — 300,00 €" });
  assertEquals(p.aps.badge, 3, "the icon carries the unread count");
  assertEquals(p.aps["thread-id"], "invoice_ready", "news of one kind stacks together");
  assertEquals(p.invoice_id, row.invoice_id, "PushCenter opens the invoice from this");
});

Deno.test("a message stacks with its own conversation", () => {
  const p = JSON.parse(apnsPayload({ ...row, kind: "message_received", thread_id: "t-1", invoice_id: null }));
  assertEquals(p.aps["thread-id"], "t-1");
});

Deno.test("without a count the badge is left as it is, not reset to zero", () => {
  const p = JSON.parse(apnsPayload({ ...row, badge: null }));
  assert(!("badge" in p.aps));
});

Deno.test("every device of the person is notified, signed and addressed to the app", async () => {
  const apple = fakeApple();
  const { deps: d, forgotten } = deps(["aaaaaaaaaaaa", "bbbbbbbbbbbb"], apple);
  const outcome = await deliver(row, d);
  assertEquals(outcome.sent, 2);
  assertEquals(apple.calls.map((c) => c.url), [
    "https://api.push.apple.com/3/device/aaaaaaaaaaaa",
    "https://api.push.apple.com/3/device/bbbbbbbbbbbb",
  ]);
  const headers = apple.calls[0].init.headers as Record<string, string>;
  assertEquals(headers.authorization, "bearer provider-jwt");
  assertEquals(headers["apns-topic"], "com.trinityenergie.energycourtage");
  assertEquals(headers["apns-push-type"], "alert");
  assertEquals(headers["apns-collapse-id"], row.id, "a retried call cannot notify twice");
  assertEquals(forgotten, []);
});

Deno.test("a phone the app was deleted from is forgotten", async () => {
  const apple = fakeApple({ "gone": { status: 410, reason: "Unregistered" } });
  const { deps: d, forgotten } = deps(["gone-token", "kept-token"], apple);
  const outcome = await deliver(row, d);
  assertEquals(forgotten, ["gone-token"]);
  assertEquals(outcome.sent, 1);
});

Deno.test("an Xcode build's token is reached through the sandbox, and kept", async () => {
  const apple = fakeApple({ "api.push.apple.com/3/device/dev": { status: 400, reason: "BadDeviceToken" } });
  const { deps: d, forgotten } = deps(["dev-token"], apple);
  const outcome = await deliver(row, d);
  assertEquals(apple.calls.map((c) => c.url), [
    "https://api.push.apple.com/3/device/dev-token",
    "https://api.sandbox.push.apple.com/3/device/dev-token",
  ]);
  assertEquals(outcome.sent, 1);
  assertEquals(outcome.results[0].environment, "sandbox");
  assertEquals(forgotten, []);
});

Deno.test("a token neither environment knows is forgotten", async () => {
  const apple = fakeApple({ "/3/device/junk": { status: 400, reason: "BadDeviceToken" } });
  const { deps: d, forgotten } = deps(["junk-token"], apple);
  await deliver(row, d);
  assertEquals(apple.calls.length, 2);
  assertEquals(forgotten, ["junk-token"]);
});

Deno.test("a mistake of ours, like a wrong topic, loses no one's device", async () => {
  const apple = fakeApple({ "/3/device/": { status: 400, reason: "DeviceTokenNotForTopic" } });
  const { deps: d, forgotten } = deps(["aaaaaaaaaaaa", "bbbbbbbbbbbb"], apple);
  const outcome = await deliver(row, d);
  assertEquals(outcome.sent, 0);
  assertEquals(outcome.results[0].reason, "DeviceTokenNotForTopic", "reported, so it can be fixed");
  assertEquals(forgotten, [], "and the tokens are all still there once it is");
});

Deno.test("someone with no registered device is simply not pushed", async () => {
  const apple = fakeApple();
  const { deps: d } = deps([], apple);
  assertEquals(await deliver(row, d), { sent: 0, results: [] });
  assertEquals(apple.calls.length, 0);
});

Deno.test("only a notification row is accepted", () => {
  assertEquals(parsePushRow({ record: row }), row);
  assertEquals(parsePushRow({ record: { kind: "x" } }), null);
  assertEquals(parsePushRow(null), null);
});

// ================================================================= Android

/** Google: the token endpoint, then FCM answering each device token from a table. */
function fakeGoogle(answers: Record<string, { status: number; body?: unknown }> = {}) {
  const calls: { url: string; init: RequestInit }[] = [];
  let exchanges = 0;
  const fetch = ((url: string, init: RequestInit) => {
    calls.push({ url, init });
    if (url.startsWith("https://oauth2.googleapis.com/token")) {
      exchanges++;
      return Promise.resolve(Response.json({ access_token: `access-${exchanges}`, expires_in: 3599 }));
    }
    if (url.startsWith("https://fcm.googleapis.com/")) {
      const token = (JSON.parse(String(init.body)) as { message: { token: string } }).message.token;
      const answer = Object.entries(answers).find(([key]) => token.includes(key))?.[1]
        ?? { status: 200, body: { name: `projects/p/messages/${token}` } };
      return Promise.resolve(new Response(answer.body ? JSON.stringify(answer.body) : null, { status: answer.status }));
    }
    // APNs
    return Promise.resolve(new Response(null, { status: 200 }));
  }) as unknown as typeof globalThis.fetch;
  return { calls, fetch, get exchanges() { return exchanges; } };
}

const fcmCalls = (g: { calls: { url: string; init: RequestInit }[] }) =>
  g.calls.filter((c) => c.url.startsWith("https://fcm.googleapis.com/"));

/** A real RSA key, so the JWT is really signed and really checked. */
async function serviceAccount() {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true, ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const b64 = btoa(String.fromCharCode(...pkcs8)).replace(/(.{64})/g, "$1\n");
  const sa: ServiceAccount = {
    project_id: "trinity-energie",
    client_email: "firebase-adminsdk@trinity-energie.iam.gserviceaccount.com",
    private_key: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`,
  };
  return { sa, publicKey: pair.publicKey };
}

const staticAuth = (): FcmAuth & { fresh: number } => {
  const auth = {
    fresh: 0,
    token: (fresh = false) => {
      if (fresh) auth.fresh++;
      return Promise.resolve(fresh ? "fresh" : "cached");
    },
  };
  return auth;
};

function dispatchDeps(devices: Device[], fetch: typeof globalThis.fetch,
                      opts: { apns?: boolean; fcm?: FcmAuth | null } = {}) {
  const forgotten: string[] = [];
  const deps: DispatchDeps = {
    devices: () => Promise.resolve(devices),
    forget: (token) => { forgotten.push(token); return Promise.resolve(); },
    apns: opts.apns === false ? null
      : { jwt: "provider-jwt", topic: "com.trinityenergie.energycourtage", environment: "production" },
    fcm: opts.fcm === null ? null : { projectId: "trinity-energie", auth: opts.fcm ?? staticAuth() },
    fetch,
  };
  return { deps, forgotten };
}

const unregistered = { status: 404, body: { error: { code: 404, message: "Requested entity was not found.",
  status: "NOT_FOUND",
  details: [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "UNREGISTERED" }] } } };
const invalidToken = { status: 400, body: { error: { code: 400,
  message: "The registration token is not a valid FCM registration token", status: "INVALID_ARGUMENT",
  details: [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "INVALID_ARGUMENT" },
            { "@type": "type.googleapis.com/google.rpc.BadRequest",
              fieldViolations: [{ field: "message.token", description: "Invalid registration token" }] }] } } };
const invalidPayload = { status: 400, body: { error: { code: 400,
  message: "Invalid value at 'message.data[0].value' (TYPE_STRING), 3", status: "INVALID_ARGUMENT",
  details: [{ "@type": "type.googleapis.com/google.rpc.BadRequest",
              fieldViolations: [{ field: "message.data[0].value", description: "Invalid value" }] }] } } };
const senderMismatch = { status: 403, body: { error: { code: 403, message: "SenderId mismatch",
  status: "PERMISSION_DENIED",
  details: [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "SENDER_ID_MISMATCH" }] } } };

Deno.test("Android: the shade shows what the list shows, on the app's channel, and a tap knows where to go", () => {
  const m = fcmMessage(row, "android-token").message;
  assertEquals(m.token, "android-token");
  assertEquals(m.notification, { title: "Facture à signer", body: "Facture FA-2026-0001 — 300,00 €" });
  assertEquals(m.android.notification.channel_id, "general");
  assertEquals(m.android.notification.tag, `n-${row.id}`, "a retry replaces its own notification");
  assertEquals(m.android.priority, "high");
  assertEquals(m.data, { kind: "invoice_ready", notification_id: row.id, invoice_id: row.invoice_id! },
               "nulls are left out, not sent as null");
  for (const value of Object.values(m.data)) assertEquals(typeof value, "string", "FCM data carries only strings");
});

Deno.test("Android: every id a notification names is in its data", () => {
  const m = fcmMessage({ ...row, kind: "message_received", thread_id: "t-1", recommendation_id: "r-1",
                         invoice_id: null }, "x").message;
  assertEquals(m.data, { kind: "message_received", notification_id: row.id, thread_id: "t-1",
                         recommendation_id: "r-1" });
});

Deno.test("one notification reaches all of the person's devices, iPhone and Android", async () => {
  const google = fakeGoogle();
  const { deps: d, forgotten } = dispatchDeps([
    { token: "ios-aaaaaaaa", platform: "ios" },
    { token: "and-aaaaaaaa", platform: "android" },
    { token: "and-bbbbbbbb", platform: "android" },
  ], google.fetch);
  const outcome = await dispatch(row, d);
  assertEquals(outcome.sent, 3);
  assertEquals(outcome.skipped, []);
  assertEquals(outcome.results.map((r) => [r.platform, r.token]), [
    ["ios", "ios-aaaa"], ["android", "and-aaaa"], ["android", "and-bbbb"],
  ]);
  assertEquals(google.calls.filter((c) => c.url.includes("push.apple.com")).map((c) => c.url),
               ["https://api.push.apple.com/3/device/ios-aaaaaaaa"]);
  const fcm = fcmCalls(google);
  assertEquals(fcm.length, 2);
  assertEquals(fcm[0].url, "https://fcm.googleapis.com/v1/projects/trinity-energie/messages:send");
  assertEquals((fcm[0].init.headers as Record<string, string>).authorization, "Bearer cached");
  assertEquals(JSON.parse(String(fcm[0].init.body)).message.token, "and-aaaaaaaa");
  assertEquals(forgotten, []);
});

Deno.test("Android: an uninstalled app's token is forgotten (404 UNREGISTERED)", async () => {
  const google = fakeGoogle({ "gone": unregistered });
  const { deps: d, forgotten } = dispatchDeps([
    { token: "gone-token", platform: "android" }, { token: "kept-token", platform: "android" },
  ], google.fetch);
  const outcome = await dispatch(row, d);
  assertEquals(forgotten, ["gone-token"]);
  assertEquals(outcome.sent, 1);
  assertEquals(outcome.results[0].reason, "UNREGISTERED: Requested entity was not found.");
  assertEquals(outcome.results[0].forgotten, true);
});

Deno.test("Android: a token that is not a token is forgotten (400 about message.token)", async () => {
  const google = fakeGoogle({ "junk": invalidToken });
  const { deps: d, forgotten } = dispatchDeps([{ token: "junk-token", platform: "android" }], google.fetch);
  await dispatch(row, d);
  assertEquals(forgotten, ["junk-token"]);
});

Deno.test("Android: a payload of ours FCM refuses loses no one's device", async () => {
  const google = fakeGoogle({ "-token": invalidPayload });
  const { deps: d, forgotten } = dispatchDeps([
    { token: "a-token", platform: "android" }, { token: "b-token", platform: "android" },
  ], google.fetch);
  const outcome = await dispatch(row, d);
  assertEquals(outcome.sent, 0);
  assertEquals(forgotten, []);
});

Deno.test("Android: a configuration error (403, another project's token) loses no one's device", async () => {
  const google = fakeGoogle({ "-token": senderMismatch });
  const { deps: d, forgotten } = dispatchDeps([{ token: "a-token", platform: "android" }], google.fetch);
  const outcome = await dispatch(row, d);
  assertEquals(outcome.results[0].status, 403);
  assertEquals(outcome.results[0].reason, "SENDER_ID_MISMATCH: SenderId mismatch", "reported, so it can be fixed");
  assertEquals(forgotten, []);
});

Deno.test("Android: only UNREGISTERED and an invalid token lose a token", () => {
  assertEquals(fcmTokenGone(404, unregistered.body), true);
  assertEquals(fcmTokenGone(400, invalidToken.body), true);
  assertEquals(fcmTokenGone(400, { error: { status: "INVALID_ARGUMENT",
    message: "The registration token is not a valid FCM registration token" } }), true);
  // a wrong project id answers 404 too, without UNREGISTERED
  assertEquals(fcmTokenGone(404, { error: { code: 404, status: "NOT_FOUND", message: "Requested entity was not found." } }),
               false);
  assertEquals(fcmTokenGone(400, invalidPayload.body), false);
  assertEquals(fcmTokenGone(403, senderMismatch.body), false);
  assertEquals(fcmTokenGone(401, {}), false);
  assertEquals(fcmTokenGone(429, { error: { status: "RESOURCE_EXHAUSTED" } }), false);
  assertEquals(fcmTokenGone(500, {}), false);
  assertEquals(fcmTokenGone(503, { error: { status: "UNAVAILABLE" } }), false);
});

Deno.test("Android: an access token Google stopped accepting is renewed once, and the push goes", async () => {
  let n = 0;
  const fetch = ((url: string, init: RequestInit) => {
    if (!url.startsWith("https://fcm.googleapis.com/")) return Promise.resolve(new Response(null, { status: 200 }));
    n++;
    const ok = (init.headers as Record<string, string>).authorization === "Bearer fresh";
    return Promise.resolve(new Response(ok ? "{}" : JSON.stringify({ error: { code: 401, status: "UNAUTHENTICATED" } }),
                                        { status: ok ? 200 : 401 }));
  }) as unknown as typeof globalThis.fetch;
  const auth = staticAuth();
  const { deps: d, forgotten } = dispatchDeps([{ token: "a-token", platform: "android" }], fetch, { fcm: auth });
  const outcome = await dispatch(row, d);
  assertEquals(n, 2);
  assertEquals(auth.fresh, 1);
  assertEquals(outcome.sent, 1);
  assertEquals(forgotten, []);
});

Deno.test("Android: a service account Google refuses keeps every token, and says why", async () => {
  const failing: FcmAuth = { token: () => Promise.reject(new Error("google token exchange 400: invalid_grant")) };
  const google = fakeGoogle();
  const { deps: d, forgotten } = dispatchDeps([
    { token: "ios-aaaaaaaa", platform: "ios" }, { token: "and-aaaaaaaa", platform: "android" },
  ], google.fetch, { fcm: failing });
  const outcome = await dispatch(row, d);
  assertEquals(outcome.sent, 1, "the iPhone still gets it");
  const android = outcome.results.find((r) => r.platform === "android")!;
  assertEquals(android.status, 0);
  assert(android.reason!.includes("invalid_grant"));
  assertEquals(fcmCalls(google).length, 0);
  assertEquals(forgotten, []);
});

Deno.test("Android: a network failure on one phone neither drops it nor stops the others", async () => {
  const fetch = ((_url: string, init: RequestInit) => {
    const token = (JSON.parse(String(init.body)) as { message: { token: string } }).message.token;
    return token === "down-token" ? Promise.reject(new TypeError("connection reset"))
                                  : Promise.resolve(new Response("{}", { status: 200 }));
  }) as unknown as typeof globalThis.fetch;
  const { deps: d, forgotten } = dispatchDeps([
    { token: "down-token", platform: "android" }, { token: "up-token", platform: "android" },
  ], fetch);
  const outcome = await dispatch(row, d);
  assertEquals(outcome.sent, 1);
  assertEquals(outcome.results[0].status, 0);
  assertEquals(forgotten, []);
});

Deno.test("without the Apple key, Android still gets its pushes and the iPhones are reported skipped", async () => {
  const google = fakeGoogle();
  const { deps: d, forgotten } = dispatchDeps([
    { token: "ios-aaaaaaaa", platform: "ios" }, { token: "and-aaaaaaaa", platform: "android" },
  ], google.fetch, { apns: false });
  const outcome = await dispatch(row, d);
  assertEquals(outcome.sent, 1);
  assertEquals(outcome.results.map((r) => r.platform), ["android"]);
  assertEquals(outcome.skipped.map((s) => [s.platform, s.count]), [["ios", 1]]);
  assertEquals(google.calls.filter((c) => c.url.includes("push.apple.com")).length, 0);
  assertEquals(forgotten, []);
});

Deno.test("without the service account, iPhones still get their pushes and Android is reported skipped", async () => {
  const google = fakeGoogle();
  const { deps: d, forgotten } = dispatchDeps([
    { token: "ios-aaaaaaaa", platform: "ios" }, { token: "and-aaaaaaaa", platform: "android" },
  ], google.fetch, { fcm: null });
  const outcome = await dispatch(row, d);
  assertEquals(outcome.sent, 1);
  assertEquals(outcome.results.map((r) => r.platform), ["ios"]);
  assertEquals(outcome.skipped,
               [{ platform: "android", count: 1, reason: "FCM is not configured (FCM_SERVICE_ACCOUNT)" }]);
  assertEquals(fcmCalls(google).length, 0);
  assertEquals(forgotten, [], "an unconfigured platform never loses its tokens");
});

Deno.test("nothing is reported skipped for a platform the person has no device on", async () => {
  const google = fakeGoogle();
  const { deps: d } = dispatchDeps([{ token: "ios-aaaaaaaa", platform: "ios" }], google.fetch, { fcm: null });
  assertEquals((await dispatch(row, d)).skipped, []);
});

Deno.test("the service account's assertion is a real RS256 JWT for the FCM scope", async () => {
  const { sa, publicKey } = await serviceAccount();
  const jwt = await signServiceAccountJwt(sa, 1_800_000_000);
  const [h, c, s] = jwt.split(".");
  const bytes = (part: string) =>
    Uint8Array.from(atob(part.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - part.length % 4) % 4)),
                    (ch) => ch.charCodeAt(0));
  const decode = (part: string) => JSON.parse(new TextDecoder().decode(bytes(part)));
  assertEquals(decode(h), { alg: "RS256", typ: "JWT" });
  assertEquals(decode(c), {
    iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token", iat: 1_800_000_000, exp: 1_800_003_600,
  });
  assert(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", publicKey, bytes(s), new TextEncoder().encode(`${h}.${c}`)),
         "signed by the service account's key");
});

Deno.test("a key pasted with its newlines escaped still signs", async () => {
  const { sa } = await serviceAccount();
  const escaped = { ...sa, private_key: sa.private_key.replace(/\n/g, "\\n") };
  assertEquals((await signServiceAccountJwt(escaped, 1)).split(".").length, 3);
});

Deno.test("the access token is exchanged once, reused for 50 minutes, then renewed", async () => {
  const { sa } = await serviceAccount();
  const google = fakeGoogle();
  let clock = 1_800_000_000_000;
  const auth = fcmAuth(sa, { fetch: google.fetch, now: () => clock });
  const [a, b] = await Promise.all([auth.token(), auth.token()]);
  assertEquals([a, b], ["access-1", "access-1"], "parallel devices share one exchange");
  const exchange = google.calls[0];
  assertEquals(exchange.url, "https://oauth2.googleapis.com/token");
  const form = new URLSearchParams(String(exchange.init.body));
  assertEquals(form.get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer");
  assertEquals(form.get("assertion")!.split(".").length, 3);
  clock += 49 * 60 * 1000;
  assertEquals(await auth.token(), "access-1");
  clock += 2 * 60 * 1000;
  assertEquals(await auth.token(), "access-2");
  assertEquals(await auth.token(true), "access-3", "a 401 asks for a fresh one");
  assertEquals(google.exchanges, 3);
});

Deno.test("Google refusing the key is an error, not a token", async () => {
  const { sa } = await serviceAccount();
  const fetch = (() => Promise.resolve(Response.json({ error: "invalid_grant", error_description: "Invalid JWT Signature." },
                                                    { status: 400 }))) as unknown as typeof globalThis.fetch;
  const auth = fcmAuth(sa, { fetch });
  let message = "";
  try { await auth.token(); } catch (e) { message = String(e); }
  assert(message.includes("invalid_grant"));
  // and the next call tries again rather than replaying the failure
  try { await auth.token(); } catch (e) { message = String(e); }
  assert(message.includes("invalid_grant"));
});

Deno.test("only a service-account key is taken as one", async () => {
  const { sa } = await serviceAccount();
  assertEquals(parseServiceAccount(JSON.stringify({ ...sa, type: "service_account" })), { ...sa, token_uri: undefined });
  assertEquals(parseServiceAccount(undefined), null);
  assertEquals(parseServiceAccount("not json"), null);
  assertEquals(parseServiceAccount(JSON.stringify({ project_id: "p" })), null);
  assertEquals(parseServiceAccount(JSON.stringify({ ...sa, private_key: "nope" })), null);
});
