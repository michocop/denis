import { assert, assertEquals } from "jsr:@std/assert@1";
import { apnsPayload, deliver, parsePushRow, PushRow } from "./handler.ts";

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
