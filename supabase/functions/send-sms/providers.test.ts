// Runs under Node (22.6+) as well as Deno:
//   node --experimental-strip-types supabase/functions/send-sms/providers.test.ts
//   deno test supabase/functions/send-sms/providers.test.ts
import { buildRequest, channelOf, smsFallback } from "./providers.ts";

const message = {
  to: "+33612345678",
  code: "042917",
  body: "Trinity Énergie : votre code de signature est 042917.",
};

let failures = 0;
function check(condition: boolean, label: string) {
  console.log(`${condition ? "PASS" : "FAIL"}  ${label}`);
  if (!condition) failures++;
}
function throws(fn: () => unknown, pattern: RegExp, label: string) {
  try {
    fn();
    check(false, label);
  } catch (error) {
    check(pattern.test((error as Error).message), label);
  }
}

const twilioEnv = { TWILIO_ACCOUNT_SID: "AC123", TWILIO_AUTH_TOKEN: "tok", TWILIO_FROM: "TRINITY" };

{
  const r = buildRequest({ ...twilioEnv }, message);
  const form = new URLSearchParams(r.init.body);
  check(r.url === "https://api.twilio.com/2010-04-01/Accounts/AC123/Messages.json",
    "twilio is the default, posted to the account's Messages endpoint");
  check(r.init.headers.authorization === "Basic " + btoa("AC123:tok"), "with basic auth");
  check(form.get("To") === "+33612345678" && form.get("From") === "TRINITY",
    "to the number, from the sender name");
  check(form.get("Body") === message.body, "carrying the full text");
}

{
  const r = buildRequest({
    ...twilioEnv, SMS_PROVIDER: "whatsapp",
    TWILIO_WHATSAPP_FROM: "+33757425237", TWILIO_WHATSAPP_CONTENT_SID: "HX999",
  }, message);
  const form = new URLSearchParams(r.init.body);
  check(form.get("To") === "whatsapp:+33612345678" && form.get("From") === "whatsapp:+33757425237",
    "whatsapp addresses both ends on the whatsapp: channel");
  check(form.get("ContentSid") === "HX999" && form.get("ContentVariables") === '{"1":"042917"}',
    "and sends the approved template with the code as its variable");
  check(!form.has("Body"), "never free text, which WhatsApp would refuse");
}

{
  const r = buildRequest({ SMS_PROVIDER: "brevo", BREVO_API_KEY: "xkeysib", BREVO_SENDER: "TRINITY" }, message);
  const body = JSON.parse(r.init.body);
  check(r.url === "https://api.brevo.com/v3/transactionalSMS/sms" && r.init.headers["api-key"] === "xkeysib",
    "brevo is posted to its transactional SMS endpoint with the API key");
  check(body.recipient === "33612345678" && body.sender === "TRINITY" && body.type === "transactional",
    "with the number stripped of its +, as Brevo expects");
}

{
  const brevo = { SMS_PROVIDER: "brevo", BREVO_API_KEY: "k", BREVO_SENDER: "TRINITY" };
  check(channelOf(brevo, message) === "sms", "with no channel given, a code goes by SMS");
  const sms = buildRequest(brevo, { ...message, channel: "sms" });
  check(sms.url.includes("brevo"), "the database's 'sms' goes to the configured SMS sender");

  const wa = buildRequest({ ...twilioEnv, ...brevo,
    TWILIO_WHATSAPP_FROM: "+33757425237", TWILIO_WHATSAPP_CONTENT_SID: "HX1" },
    { ...message, channel: "whatsapp" });
  check(new URLSearchParams(wa.init.body).get("To") === "whatsapp:+33612345678",
    "'whatsapp' goes to WhatsApp whatever the SMS sender is");

  const fallback = smsFallback(brevo, { ...message, channel: "whatsapp" });
  check(fallback !== null && fallback.url.includes("brevo"),
    "when WhatsApp refuses, the same code can go by SMS");
  check(smsFallback({}, message) === null, "and there is no fallback when no SMS sender is set up");
}

throws(() => buildRequest({ TWILIO_ACCOUNT_SID: "AC123" }, message), /missing TWILIO_AUTH_TOKEN, TWILIO_FROM/,
  "a missing secret is named, not a crash");
throws(() => buildRequest({ ...twilioEnv, SMS_PROVIDER: "carrier-pigeon" }, message), /unknown SMS_PROVIDER/,
  "an unknown provider is refused");
throws(() => buildRequest(twilioEnv, { ...message, to: "0612345678" }), /E\.164/,
  "a number that was not normalised is refused rather than misdelivered");
throws(() => buildRequest(twilioEnv, { ...message, code: "12ab56" }), /six digits/,
  "and so is anything that is not a six-digit code");

if (failures) {
  console.log(`\n${failures} FAILED`);
  // deno-lint-ignore no-explicit-any
  (globalThis as any).process?.exit?.(1);
  throw new Error(`${failures} failed`);
}
console.log("\nALL PASSED");
