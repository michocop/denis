/**
 * Trinity Énergie : réception des formulaires du site (version Vercel).
 * Même rôle que envoi.php, pour un hébergement sans PHP :
 *  - type=facture : facture jointe + coordonnées, envoyées par e-mail.
 *  - type=rappel  : demande de rappel d'échéance, avec un rendez-vous agenda (.ics) joint.
 * Rien n'est stocké. L'e-mail part via Resend (resend.com).
 *
 * Variables d'environnement (Vercel → Settings → Environment Variables) :
 *  RESEND_API_KEY  obligatoire, la clé « re_… » créée sur resend.com
 *  MAIL_TO         facultatif, destinataire (par défaut pierrelouis@trinity-energie.fr)
 *  MAIL_FROM       facultatif, expéditeur. Tant que le domaine n'est pas vérifié sur Resend,
 *                  laisser vide : l'envoi part de onboarding@resend.dev, et Resend n'accepte
 *                  alors comme destinataire que l'adresse du compte Resend.
 */

const TAILLE_MAX = 4 * 1024 * 1024; // Vercel refuse les requêtes de plus de 4,5 Mo

const repondre = (code, ok, message = '') =>
  new Response(JSON.stringify({ ok, message }), {
    status: code,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'X-Content-Type-Options': 'nosniff' },
  });

const champ = (fd, nom) => String(fd.get(nom) ?? '').trim().slice(0, 300).replace(/[\r\n\0]/g, ' ');

const EMAIL_OK = /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]{2,}$/;

// Type réel du fichier, d'après ses premiers octets (pas d'après ce que le navigateur annonce)
function typeReel(octets) {
  const d = octets.subarray(0, 8);
  if (d[0] === 0x25 && d[1] === 0x50 && d[2] === 0x44 && d[3] === 0x46) return ['application/pdf', 'pdf'];
  if (d[0] === 0xff && d[1] === 0xd8 && d[2] === 0xff) return ['image/jpeg', 'jpg'];
  if (d[0] === 0x89 && d[1] === 0x50 && d[2] === 0x4e && d[3] === 0x47) return ['image/png', 'png'];
  return null;
}

const jj = (d) => String(d.getUTCDate()).padStart(2, '0') + '/' + String(d.getUTCMonth() + 1).padStart(2, '0') + '/' + d.getUTCFullYear();
const ics = (d) => d.toISOString().slice(0, 10).replace(/-/g, '');

async function envoyer({ sujet, texte, piece, replyTo }) {
  const cle = process.env.RESEND_API_KEY;
  if (!cle) return false;
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${cle}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: process.env.MAIL_FROM || 'Site Trinity Énergie <onboarding@resend.dev>',
      to: [process.env.MAIL_TO || 'pierrelouis@trinity-energie.fr'],
      reply_to: replyTo,
      subject: sujet,
      text: texte,
      attachments: [{ filename: piece.nom, content: Buffer.from(piece.data).toString('base64'), content_type: piece.type }],
    }),
  });
  if (!res.ok) console.error('Resend', res.status, await res.text());
  return res.ok;
}

export async function POST(request) {
  if (Number(request.headers.get('content-length') || 0) > TAILLE_MAX + 64 * 1024)
    return repondre(413, false, 'Fichier trop lourd (4 Mo maximum).');
  let fd;
  try { fd = await request.formData(); } catch { return repondre(400, false, 'Demande illisible.'); }

  // Anti-robots : champ caché rempli ou envoi instantané
  if (champ(fd, 'site_web') !== '') return repondre(200, true);
  if (Number(champ(fd, 'duree')) < 1500) return repondre(400, false, 'Envoi trop rapide, merci de réessayer.');

  const type = champ(fd, 'type');
  const email = champ(fd, 'email');
  if (!EMAIL_OK.test(email)) return repondre(400, false, 'Adresse e-mail invalide.');

  let ok;
  if (type === 'facture') {
    const nom = champ(fd, 'nom'), entreprise = champ(fd, 'entreprise'), tel = champ(fd, 'tel');
    if (!nom || !entreprise || !tel) return repondre(400, false, 'Merci de remplir tous les champs.');
    if (champ(fd, 'rgpd') !== 'oui') return repondre(400, false, 'Merci d’accepter l’utilisation de vos informations.');
    const f = fd.get('facture');
    if (!f || typeof f === 'string' || !f.size) return repondre(400, false, 'La facture n’a pas été reçue.');
    if (f.size > TAILLE_MAX) return repondre(400, false, 'Fichier trop lourd (4 Mo maximum).');
    const data = new Uint8Array(await f.arrayBuffer());
    const t = typeReel(data);
    if (!t) return repondre(400, false, 'Format non pris en charge (PDF, JPG ou PNG).');
    const base = (f.name || 'facture').replace(/\.[^.]*$/, '').replace(/[^A-Za-z0-9._-]+/g, '-').slice(0, 60).replace(/^-+|-+$/g, '');
    const texte = 'Nouvelle facture à analyser, reçue via trinity-energie.fr\n\n'
      + `Nom : ${nom}\nEntreprise : ${entreprise}\nTéléphone : ${tel}\nE-mail : ${email}\n\n`
      + 'La facture est jointe. Engagement affiché : rappel sous 48 heures ouvrées.\n';
    ok = await envoyer({ sujet: `Facture à analyser – ${entreprise}`, texte, replyTo: email,
      piece: { type: t[0], nom: `facture-${base || 'client'}.${t[1]}`, data } });
  } else if (type === 'rappel') {
    const fin = champ(fd, 'finContrat');
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(fin);
    const d = m && new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
    if (!d || d.getUTCDate() !== +m[3]) return repondre(400, false, 'Date de fin de contrat invalide.');
    const debut = new Date(d); debut.setUTCMonth(debut.getUTCMonth() - 6);
    const demain = new Date(); demain.setUTCHours(0, 0, 0, 0); demain.setUTCDate(demain.getUTCDate() + 1);
    if (debut < demain) debut.setTime(demain.getTime());
    const lendemain = new Date(debut); lendemain.setUTCDate(lendemain.getUTCDate() + 1);
    const agenda = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Trinity Energie//Site//FR\r\nMETHOD:PUBLISH\r\nBEGIN:VEVENT\r\n'
      + `UID:${crypto.randomUUID()}@trinity-energie.fr\r\nDTSTAMP:${new Date().toISOString().replace(/[-:]|\.\d+/g, '')}\r\n`
      + `DTSTART;VALUE=DATE:${ics(debut)}\r\nDTEND;VALUE=DATE:${ics(lendemain)}\r\n`
      + `SUMMARY:Relancer ${email} (fin de contrat le ${jj(d)})\r\n`
      + `DESCRIPTION:Demande de rappel reçue via le site. Contact : ${email}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n`;
    const texte = "Demande de rappel d'échéance, reçue via trinity-energie.fr\n\n"
      + `E-mail : ${email}\nFin de contrat : ${jj(d)}\nÀ recontacter à partir du : ${jj(debut)}\n\n`
      + 'Le site a promis au client un e-mail à cette date. Un rendez-vous agenda est joint.\n';
    ok = await envoyer({ sujet: `Rappel d’échéance – fin de contrat le ${jj(d)}`, texte, replyTo: email,
      piece: { type: 'text/calendar', nom: 'rappel-trinity.ics', data: new TextEncoder().encode(agenda) } });
  } else {
    return repondre(400, false, 'Demande inconnue.');
  }

  if (!ok) return repondre(500, false, 'L’e-mail n’a pas pu partir.');
  return repondre(200, true);
}

export function GET() {
  return repondre(405, false, 'Méthode non autorisée.');
}
