// The look of every email: the website's night navy, its one blue, the
// TRINITY ÉNERGIE wordmark. Table layout and inline styles, because that is
// what mail clients render; a plain-text part goes with every HTML one.

import { html } from "./email.ts";

export interface Letter {
  /** First line, e.g. "Bonjour Johann,". */
  greeting: string;
  /** Short heading in the brand's display weight. */
  heading: string;
  /** Paragraphs, plain text. */
  paragraphs: string[];
  /** A real button, for mail that leads somewhere (an invitation, a reset).
   *  `plain` writes the address as text instead: Brevo rewrites every <a> in
   *  a transactional mail through its click-tracking redirect, which cannot be
   *  turned off per message and answered "lien temporairement indisponible"
   *  to the first invitation. A one-time link must reach Supabase untouched;
   *  as text, the phone's mail app makes it tappable and Brevo leaves it be. */
  action?: { label: string; url: string; plain?: boolean };
  /** A one-time code, set large in place of a button: sign-in mail carries
   *  no link at all, so there is nothing for click tracking to break. */
  code?: string;
  /** Replaces the notification footer, for account mail nobody can turn off. */
  footerNote?: string;
}

export function renderLetter(letter: Letter): { html: string; text: string } {
  const text = [letter.greeting, "", letter.heading, "", ...letter.paragraphs.flatMap((p) => [p, ""]),
    ...(letter.code ? [`Votre code : ${letter.code}`, ""] : []),
    ...(letter.action ? [`${letter.action.label} : ${letter.action.url}`, ""] : []),
    "Trinity Énergie — courtier en électricité et gaz", "https://trinity-energie.fr"].join("\n");
  const code = letter.code
    ? `<span style="display:inline-block;background:#eef2fb;border:1px solid #d6def0;border-radius:14px;padding:14px 22px;font-family:Sora,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-weight:600;font-size:32px;letter-spacing:10px;color:#03081A">${html(letter.code)}</span>`
    : "";
  const button = letter.code && !letter.action
    ? code
    : letter.action?.plain
    ? `<span style="display:block;font-size:13px;font-weight:600;color:#03081A;margin:0 0 6px">${html(letter.action.label)} — touchez le lien :</span>`
      + `<span style="display:block;background:#eef2fb;border-radius:12px;padding:12px 14px;font-size:13px;line-height:1.5;color:#1F5FFF;word-break:break-all">${html(letter.action.url)}</span>`
    : letter.action
    ? `<a href="${html(letter.action.url)}" style="display:inline-block;background:#1F5FFF;color:#ffffff;border-radius:999px;padding:13px 24px;font-weight:600;font-size:15px;text-decoration:none">${html(letter.action.label)}</a>`
    : `<span style="display:inline-block;background:#1F5FFF;color:#ffffff;border-radius:999px;padding:12px 22px;font-weight:600;font-size:15px">Ouvrez l'application Trinity Énergie</span>`;
  const footer = html(letter.footerNote ??
    "Vous recevez cet e-mail parce que vous utilisez l'application Trinity Énergie. Vous pouvez désactiver ces e-mails dans votre profil.");

  const body = letter.paragraphs
    .map((p) => `<p style="margin:0 0 14px;font-size:15px;line-height:1.6;color:#2b3550">${html(p)}</p>`)
    .join("");

  const page = `<!doctype html>
<html lang="fr"><body style="margin:0;padding:0;background:#eef2fb">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef2fb;padding:24px 0">
<tr><td align="center">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#ffffff;border-radius:18px;overflow:hidden;font-family:Manrope,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif">
<tr><td style="background:#03081A;background-image:linear-gradient(160deg,#0A1F4A,#03081A);padding:22px 28px">
<span style="font-family:Sora,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-weight:600;font-size:13px;letter-spacing:3px;color:#F5F7FC">&#9651; TRINITY ÉNERGIE</span>
</td></tr>
<tr><td style="padding:28px">
<p style="margin:0 0 6px;font-size:15px;color:#2b3550">${html(letter.greeting)}</p>
<h1 style="margin:0 0 18px;font-family:Sora,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-weight:600;font-size:22px;line-height:1.3;color:#03081A">${html(letter.heading)}</h1>
${body}
${letter.code && letter.action ? `<p style="margin:22px 0 0">${code}</p>` : ""}
<p style="margin:22px 0 0">${button}</p>
</td></tr>
<tr><td style="padding:18px 28px;border-top:1px solid #e3e8f4;font-size:12px;color:#7a86a3">
Trinity Énergie — courtier en électricité et gaz · <a href="https://trinity-energie.fr" style="color:#1F5FFF;text-decoration:none">trinity-energie.fr</a><br>
${footer}
</td></tr>
</table></td></tr></table></body></html>`;
  return { html: page, text };
}
