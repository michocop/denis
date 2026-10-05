import { assert, assertEquals } from "jsr:@std/assert@1";
import { maskForLog, parseSms, senderName, sendSms } from "./handler.ts";

function fakeBrevo(status: number, body: unknown) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetch = ((url: string, init: RequestInit) => {
    calls.push({ url, init });
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  }) as unknown as typeof globalThis.fetch;
  return { calls, fetch };
}

Deno.test("a code is sent through Brevo as a transactional SMS, from Trinity", async () => {
  const brevo = fakeBrevo(201, { messageId: 1511882900176220 });
  const outcome = await sendSms(
    { to: "+33612345678", text: "Trinity Énergie : 123456 est votre code de vérification." },
    { apiKey: "xkeysib-test", fetch: brevo.fetch },
  );
  assertEquals(outcome, { status: "sent", message_id: "1511882900176220" });
  assertEquals(brevo.calls[0].url, "https://api.brevo.com/v3/transactionalSMS/send");
  assertEquals((brevo.calls[0].init.headers as Record<string, string>)["api-key"], "xkeysib-test");
  const body = JSON.parse(brevo.calls[0].init.body as string);
  assertEquals(body.recipient, "33612345678", "Brevo takes the number without its +");
  assertEquals(body.sender, "Trinity");
  assertEquals(body.type, "transactional");
  assert(body.content.includes("123456"));
});

Deno.test("Brevo refusing the SMS is reported, not hidden", async () => {
  const brevo = fakeBrevo(400, { code: "not_enough_credits", message: "Not enough credits" });
  const outcome = await sendSms({ to: "+33612345678", text: "x" }, { apiKey: "k", fetch: brevo.fetch });
  assertEquals(outcome, { status: "rejected", error: "Not enough credits" });
});

Deno.test("without an API key nothing is sent", async () => {
  const brevo = fakeBrevo(201, {});
  const outcome = await sendSms({ to: "+33612345678", text: "x" }, { apiKey: undefined, fetch: brevo.fetch });
  assertEquals(outcome.status, "not_configured");
  assertEquals(brevo.calls.length, 0);
});

Deno.test("only a number in international form and a text are accepted", () => {
  assertEquals(parseSms({ to: "+33612345678", text: "hi" }), { to: "+33612345678", text: "hi" });
  assertEquals(parseSms({ to: "0612345678", text: "hi" }), null);
  assertEquals(parseSms({ to: "+33612345678", text: "  " }), null);
  assertEquals(parseSms({ to: "+33612345678" }), null);
  assertEquals(parseSms(null), null);
});

Deno.test("the sender is one Brevo accepts, and the logs never hold the number", () => {
  assertEquals(senderName("Trinity Énergie"), "TrinityEner");
  assertEquals(senderName(undefined), "Trinity");
  assertEquals(senderName("!!"), "Trinity");
  assertEquals(maskForLog("+33612345678"), "+336•••••78");
});
