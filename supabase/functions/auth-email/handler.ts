// Supabase Auth's own emails -- invitation, password reset, email change --
// written in the brand's letterhead and sent through the project's provider
// (Brevo), instead of Supabase's shared SMTP, which only reaches the project's
// own team and a few messages an hour.
//
// Supabase calls this as its "send email" hook: https://supabase.com/docs/guides/auth/auth-hooks/send-email-hook

import { Mail } from "../_shared/email.ts";
import { renderLetter } from "../_shared/email_template.ts";

export interface HookPayload {
  user: { email: string; new_email?: string | null; user_metadata?: Record<string, unknown> | null };
  email_data: {
    token?: string;
    token_hash: string;
    redirect_to?: string | null;
    email_action_type: string;
    site_url?: string | null;
    token_hash_new?: string | null;
  };
}

const APP_REDIRECT = "trinityenergie://auth-callback";

/** Where the app is installed from while it is in beta. */
export const INSTALL_URL = "https://testflight.apple.com/join/cmSnjrEh";

/** The link the button opens: Supabase verifies it, then hands over to the app. */
export function verifyLink(supabaseUrl: string, tokenHash: string, type: string, redirectTo?: string | null): string {
  const params = new URLSearchParams({ token: tokenHash, type, redirect_to: redirectTo || APP_REDIRECT });
  return `${supabaseUrl.replace(/\/$/, "")}/auth/v1/verify?${params}`;
}

const FOOTER = "Cet e-mail concerne l'accès à votre compte Trinity Énergie. Si vous n'êtes pas à l'origine de cette demande, ignorez-le : rien ne change sans vous.";

export function authMail(payload: HookPayload, supabaseUrl: string): Mail {
  const d = payload.email_data;
  const firstName = typeof payload.user.user_metadata?.first_name === "string"
    ? payload.user.user_metadata.first_name as string : null;
  const greeting = firstName ? `Bonjour ${firstName},` : "Bonjour,";
  const link = (type = d.email_action_type, hash = d.token_hash) => verifyLink(supabaseUrl, hash, type, d.redirect_to);

  let subject: string, heading: string, paragraphs: string[], label: string;
  let to = payload.user.email;
  switch (d.email_action_type) {
    case "invite":
      return invitationMail(to, greeting);
    case "recovery":
      subject = "Réinitialisez votre mot de passe";
      heading = "Choisissez un nouveau mot de passe";
      paragraphs = ["Une réinitialisation a été demandée pour votre compte. Ouvrez ce lien depuis votre iPhone : l'application vous demandera votre nouveau mot de passe.",
        "Le lien n'est valable qu'une heure et une seule fois."];
      label = "Réinitialiser mon mot de passe";
      break;
    case "email_change":
      subject = "Confirmez votre nouvelle adresse e-mail";
      heading = "Confirmez votre nouvelle adresse";
      paragraphs = ["Ouvrez ce lien pour confirmer l'adresse qui sera désormais associée à votre compte."];
      label = "Confirmer l'adresse";
      if (payload.user.new_email && d.token_hash_new) {
        to = payload.user.new_email;
        return letter(to, subject, greeting, heading, paragraphs, label, link("email_change", d.token_hash_new));
      }
      break;
    case "magiclink":
    case "signup": // the first code of an invited address nobody confirmed yet
      if (d.token) return codeMail(to, greeting, d.token);
      subject = "Votre lien de connexion";
      heading = "Connectez-vous à Trinity Énergie";
      paragraphs = ["Ouvrez ce lien depuis votre iPhone pour vous connecter."];
      label = "Me connecter";
      break;
    default: // reauthentication...
      subject = "Confirmez votre adresse e-mail";
      heading = "Confirmez votre adresse";
      paragraphs = d.token
        ? [`Votre code : ${d.token}`]
        : ["Ouvrez ce lien pour confirmer votre adresse."];
      label = "Confirmer";
  }
  return letter(to, subject, greeting, heading, paragraphs, label, link());
}

/** No sign-in link: the app signs in by emailed code, so the invitation only
 *  has to say where the app is and which address to type. Sent by
 *  send-invite itself, and by this hook if an invitation ever comes from the
 *  dashboard. */
export function invitationMail(to: string, greeting = "Bonjour,"): Mail {
  return letter(to, "Votre invitation à rejoindre Trinity Énergie", greeting,
    "Votre accès Trinity Énergie est ouvert", [
      "Trinity Énergie vous ouvre un accès apporteur d'affaires : vous recommandez des professionnels, suivez chaque dossier et signez vos factures depuis l'application.",
      "Installez l'application sur votre iPhone, ouvrez-la et saisissez cette adresse e-mail : vous recevrez un code de connexion à six chiffres. Aucun mot de passe à retenir.",
    ], "Installer l'application", INSTALL_URL);
}

/** The sign-in code, and nothing to click. The code leads the subject so the
 *  lock screen shows it and iOS offers it above the keyboard. */
function codeMail(to: string, greeting: string, code: string): Mail {
  const rendered = renderLetter({
    greeting,
    heading: "Votre code de connexion",
    paragraphs: ["Saisissez ce code dans l'application Trinity Énergie. Il est valable une heure et ne sert qu'une fois."],
    code,
    footerNote: FOOTER,
  });
  return { to: [to], subject: `${code} est votre code Trinity Énergie`, text: rendered.text, html: rendered.html };
}

function letter(to: string, subject: string, greeting: string, heading: string,
                paragraphs: string[], label: string, url: string): Mail {
  const rendered = renderLetter({ greeting, heading, paragraphs, action: { label, url, plain: true }, footerNote: FOOTER });
  return { to: [to], subject, text: rendered.text, html: rendered.html };
}
