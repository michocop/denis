// Emails a notification that is worth one -- an invoice to sign, a payment,
// a reminder, an alert for the company -- to the person it is addressed to.
// The text is the one the push and the in-app list show, rendered in SQL by
// notification_title/notification_body, so the three cannot disagree.

import { SendMail } from "../_shared/email.ts";
import { renderLetter } from "../_shared/email_template.ts";

export interface NotificationEmail {
  to: string;
  first_name: string | null;
  kind: string;
  title: string;
  body: string;
}

export interface Deps {
  /** null when there is nobody to send to (email off, deleted account). */
  load(notificationId: string): Promise<NotificationEmail | null>;
  sendMail: SendMail;
}

/** What each kind asks of the reader, below the notification's own line. */
const NEXT_STEP: Record<string, string> = {
  invoice_ready: "Ouvrez-la dans l'application pour la relire et la signer : le paiement suit la signature des deux parties.",
  reward_earned: "Votre commission est acquise. La facture correspondante vous sera proposée à la signature.",
  payment_sent: "Le virement est en route vers le compte que vous nous avez indiqué.",
  reminder_due: "C'est le moment prévu pour cette relance.",
  lead_created: "Une nouvelle recommandation attend d'être prise en charge.",
  member_pending: "Un nouveau membre attend votre validation dans la console Apporteurs.",
  invoice_signed_by_apporteur: "L'apporteur a signé : il ne manque plus que la signature de l'entreprise.",
  document_added: "Un document a été joint à une recommandation.",
  member_approved: "Ouvrez l'application et saisissez votre adresse e-mail : un code de connexion vous sera envoyé.",
};

export async function sendNotificationEmail(notificationId: string, deps: Deps) {
  const n = await deps.load(notificationId);
  if (!n || !n.to) return { notification_id: notificationId, status: "no_recipient" as const };

  const letter = renderLetter({
    greeting: n.first_name ? `Bonjour ${n.first_name},` : "Bonjour,",
    heading: n.title,
    paragraphs: [n.body, NEXT_STEP[n.kind] ?? ""].filter(Boolean),
  });
  const status = await deps.sendMail({
    to: [n.to],
    subject: `${n.title}${n.body ? ` — ${n.body}` : ""}`.slice(0, 140),
    text: letter.text,
    html: letter.html,
  });
  return { notification_id: notificationId, status };
}
