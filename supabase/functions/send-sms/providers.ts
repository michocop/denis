// Energy Courtage — how a signature code becomes a request to a provider.
//
// Kept apart from the HTTP handler and free of Deno globals, so the request
// each provider receives can be checked without sending anything (see
// providers.test.ts). Switching provider is a secret, not a code change.
//
// The database says which channel each code goes on (sms_config.channel,
// WhatsApp by default; SMS when the signer asks for it):
//
//   WhatsApp   TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_WHATSAPP_FROM (the
//              approved WhatsApp sender, +33...) and TWILIO_WHATSAPP_CONTENT_SID
//              (an approved "authentication" template whose {{1}} is the code).
//              WhatsApp refuses free text to someone who has not written
//              first, so a template is not optional.
//   SMS        SMS_PROVIDER picks who sends it:
//              brevo   BREVO_API_KEY, BREVO_SENDER (11 letters or digits max)
//              twilio  TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM (a
//                      number, or a sender name such as TRINITY)
//
// SMS_PROVIDER=whatsapp, from before channels existed, still means "WhatsApp
// unless told otherwise", with Twilio as the SMS sender.

export interface Message {
  /** E.164, already normalised by the database: +33612345678 */
  to: string;
  /** the six digits on their own, for template-based channels */
  code: string;
  /** the full text, for plain SMS */
  body: string;
  /** chosen by the database; absent from callers older than channels */
  channel?: "whatsapp" | "sms";
}

export interface ProviderRequest {
  url: string;
  init: { method: "POST"; headers: Record<string, string>; body: string };
}

type Env = Record<string, string | undefined>;

function need(env: Env, ...keys: string[]): string[] {
  const missing = keys.filter((k) => !env[k]);
  if (missing.length) {
    throw new Error(`SMS is not configured: missing ${missing.join(", ")}`);
  }
  return keys.map((k) => env[k]!);
}

function twilio(env: Env, form: Record<string, string>): ProviderRequest {
  const [sid, token] = need(env, "TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN");
  return {
    url: `https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`,
    init: {
      method: "POST",
      headers: {
        authorization: "Basic " + btoa(`${sid}:${token}`),
        "content-type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams(form).toString(),
    },
  };
}

export function buildRequest(env: Env, message: Message): ProviderRequest {
  if (!/^\+[1-9][0-9]{7,14}$/.test(message.to)) {
    throw new Error("recipient is not an E.164 number");
  }
  if (!/^[0-9]{6}$/.test(message.code)) {
    throw new Error("code is not six digits");
  }

  if (channelOf(env, message) === "whatsapp") {
    const [, , from, contentSid] = need(env, "TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN",
      "TWILIO_WHATSAPP_FROM", "TWILIO_WHATSAPP_CONTENT_SID");
    return twilio(env, {
      To: `whatsapp:${message.to}`,
      From: `whatsapp:${from}`,
      ContentSid: contentSid,
      ContentVariables: JSON.stringify({ "1": message.code }),
    });
  }

  const provider = (env.SMS_PROVIDER ?? "twilio").toLowerCase();
  switch (provider === "whatsapp" ? "twilio" : provider) {
    case "twilio": {
      const [, , from] = need(env, "TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM");
      return twilio(env, { To: message.to, From: from, Body: message.body });
    }
    case "brevo": {
      const [key, sender] = need(env, "BREVO_API_KEY", "BREVO_SENDER");
      return {
        url: "https://api.brevo.com/v3/transactionalSMS/sms",
        init: {
          method: "POST",
          headers: { "api-key": key, "content-type": "application/json", accept: "application/json" },
          body: JSON.stringify({
            type: "transactional",
            sender,
            // Brevo wants the number without the leading +
            recipient: message.to.slice(1),
            content: message.body,
          }),
        },
      };
    }
    default:
      throw new Error(`unknown SMS_PROVIDER "${env.SMS_PROVIDER}" (brevo or twilio)`);
  }
}

export function channelOf(env: Env, message: Message): "whatsapp" | "sms" {
  if (message.channel) return message.channel;
  return (env.SMS_PROVIDER ?? "").toLowerCase() === "whatsapp" ? "whatsapp" : "sms";
}

/** The same code by SMS, for when WhatsApp refused it. Null when no SMS sender is set up. */
export function smsFallback(env: Env, message: Message): ProviderRequest | null {
  try {
    return buildRequest(env, { ...message, channel: "sms" });
  } catch {
    return null;
  }
}
