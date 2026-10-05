// Transactional email, through Brevo -- the account that already sends the SMS
// codes, 300 emails a day on its free plan -- or through Resend when a Resend
// key is set instead.
//
// Optional by design: with no key, or no verified sender in MAIL_FROM, the
// caller learns the mail was not sent and carries on, which is the state a
// project is in before an email provider is set up.

export interface Attachment {
  filename: string;
  content: Uint8Array;
}

export interface Mail {
  to: string[];
  subject: string;
  text: string;
  html: string;
  attachments?: Attachment[];
}

export type SendMail = (mail: Mail) => Promise<"sent" | "not_configured">;

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function resendSender(
  apiKey = Deno.env.get("RESEND_API_KEY"),
  from = Deno.env.get("MAIL_FROM") ?? "Trinity Énergie <factures@trinity-energie.fr>",
  fetcher: typeof fetch = fetch,
): SendMail {
  return async (mail) => {
    if (!apiKey) return "not_configured";
    const response = await fetcher("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from,
        to: mail.to,
        subject: mail.subject,
        text: mail.text,
        html: mail.html,
        attachments: (mail.attachments ?? []).map((a) => ({
          filename: a.filename,
          content: base64(a.content),
        })),
      }),
    });
    if (!response.ok) {
      throw new Error(`email provider refused the message: ${response.status} ${await response.text()}`);
    }
    return "sent";
  };
}

/** "Trinity Énergie <factures@x.fr>" -> its name and address. */
export function parseFrom(from: string): { name?: string; email: string } {
  const m = from.match(/^\s*(.*?)\s*<([^>]+)>\s*$/);
  return m ? { name: m[1] || undefined, email: m[2] } : { email: from.trim() };
}

export function brevoSender(
  apiKey = Deno.env.get("BREVO_API_KEY"),
  from = Deno.env.get("MAIL_FROM"),
  fetcher: typeof fetch = fetch,
): SendMail {
  return async (mail) => {
    // the sender has to be one Brevo has verified, so there is no default
    if (!apiKey || !from) return "not_configured";
    const response = await fetcher("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: { "api-key": apiKey, "content-type": "application/json", "accept": "application/json" },
      body: JSON.stringify({
        sender: parseFrom(from),
        to: mail.to.map((email) => ({ email })),
        subject: mail.subject,
        htmlContent: mail.html,
        textContent: mail.text,
        ...(mail.attachments?.length
          ? { attachment: mail.attachments.map((a) => ({ name: a.filename, content: base64(a.content) })) }
          : {}),
      }),
    });
    if (!response.ok) {
      throw new Error(`email provider refused the message: ${response.status} ${await response.text()}`);
    }
    return "sent";
  };
}

/** The provider this project has: Resend if its key is set, Brevo otherwise. */
export function mailSender(): SendMail {
  return Deno.env.get("RESEND_API_KEY") ? resendSender() : brevoSender();
}

/** Escapes text for the small HTML bodies these mails carry. */
export function html(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
