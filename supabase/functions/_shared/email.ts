// Transactional email through Resend (https://resend.com), EU region.
//
// Optional by design: with no RESEND_API_KEY the caller learns the mail was
// not sent and carries on, which is the state a project is in before an email
// provider is set up. Supabase's own SMTP is for auth mail at a handful an
// hour, not for invoices.

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

/** Escapes text for the small HTML bodies these mails carry. */
export function html(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
