// Sends one SMS through Brevo: a verification or signing code, written in SQL
// by request_sms_code(). The code is in the text and nowhere else, so neither
// is logged here.
//
// Brevo: https://developers.brevo.com/reference/sendtransacsms
// France, about €0.045 an SMS, bought in packs that do not expire.

export interface Sms {
  to: string;   // E.164, "+33612345678"
  text: string;
}

export type SmsOutcome =
  | { status: "sent"; message_id: string | null }
  | { status: "rejected"; error: string }
  | { status: "not_configured" };

export interface BrevoConfig {
  apiKey: string | undefined;
  /** 3 to 11 letters or digits; shown as the sender on the phone. */
  sender?: string;
  fetch?: typeof fetch;
}

const ENDPOINT = "https://api.brevo.com/v3/transactionalSMS/send";

/** The sender Brevo accepts: alphanumeric, 11 characters at most. */
export function senderName(raw: string | undefined): string {
  const cleaned = (raw ?? "").normalize("NFD").replace(/[^A-Za-z0-9]/g, "").slice(0, 11);
  return cleaned.length >= 3 ? cleaned : "Trinity";
}

export function parseSms(body: unknown): Sms | null {
  if (!body || typeof body !== "object") return null;
  const { to, text } = body as Record<string, unknown>;
  if (typeof to !== "string" || !/^\+[1-9][0-9]{7,14}$/.test(to)) return null;
  if (typeof text !== "string" || text.trim() === "" || text.length > 459) return null;
  return { to, text };
}

export async function sendSms(sms: Sms, config: BrevoConfig): Promise<SmsOutcome> {
  if (!config.apiKey) return { status: "not_configured" };
  const response = await (config.fetch ?? fetch)(ENDPOINT, {
    method: "POST",
    headers: {
      "api-key": config.apiKey,
      "content-type": "application/json",
      "accept": "application/json",
    },
    body: JSON.stringify({
      sender: senderName(config.sender),
      recipient: sms.to.slice(1),          // Brevo wants 33612345678, no "+"
      content: sms.text,
      type: "transactional",
      tag: "trinity-code",
    }),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    return { status: "rejected", error: String(payload?.message ?? `HTTP ${response.status}`) };
  }
  return { status: "sent", message_id: payload?.messageId != null ? String(payload.messageId) : null };
}

/** "+33612345678" -> "+336•••••78", for logs. */
export function maskForLog(e164: string): string {
  return e164.length > 6 ? `${e164.slice(0, 4)}•••••${e164.slice(-2)}` : "•••";
}
