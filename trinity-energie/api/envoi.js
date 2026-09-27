/**
 * Trinity Énergie : réception des formulaires du site (version Vercel de envoi.php).
 *  - type=facture : facture jointe + coordonnées, envoyées par e-mail.
 *  - type=rappel  : demande de rappel d'échéance, avec un rendez-vous agenda (.ics) joint.
 * Envoi par la messagerie Hostinger (SMTP). Rien n'est stocké.
 * Variables d'environnement : SMTP_USER, SMTP_PASS (obligatoires), SMTP_HOST, SMTP_PORT, MAIL_TO (facultatives).
 */
const Busboy = require('busboy');
const nodemailer = require('nodemailer');

const DESTINATAIRE = process.env.MAIL_TO || 'pierrelouis@trinity-energie.fr';
const TAILLE_MAX = 4 * 1024 * 1024; // Vercel limite une requête à 4,5 Mo
const SIGNATURES = [['application/pdf', 'pdf', [0x25, 0x50, 0x44, 0x46]], ['image/jpeg', 'jpg', [0xff, 0xd8, 0xff]], ['image/png', 'png', [0x89, 0x50, 0x4e, 0x47]]];

function repondre(res, code, ok, message = '') {
  res.statusCode = code;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify({ ok, message }));
}

function lire(req) {
  return new Promise((resolve, reject) => {
    let bb;
    try { bb = Busboy({ headers: req.headers, limits: { fileSize: TAILLE_MAX, files: 1, fields: 20, fieldSize: 4000 } }); }
    catch (e) { reject(e); return; }
    const champs = {}; let fichier = null; let tropLourd = false;
    bb.on('field', (nom, val) => { champs[nom] = String(val).replace(/[\r\n\0]+/g, ' ').trim().slice(0, 300); });
    bb.on('file', (nom, flux, info) => {
      const morceaux = [];
      flux.on('data', (d) => morceaux.push(d));
      flux.on('limit', () => { tropLourd = true; });
      flux.on('end', () => { if (nom === 'facture') fichier = { nom: info.filename || 'facture', donnees: Buffer.concat(morceaux) }; });
    });
    bb.on('error', reject);
    bb.on('close', () => resolve({ champs, fichier, tropLourd }));
    req.pipe(bb);
  });
}

function typeFichier(buf) {
  for (const [mime, ext, sig] of SIGNATURES) if (sig.every((o, i) => buf[i] === o)) return { mime, ext };
  return null;
}

const frDate = (d) => d.toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit', year: 'numeric', timeZone: 'Europe/Paris' });
const ymd = (d) => `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;

module.exports = async function envoi(req, res) {
  if (req.method !== 'POST') return repondre(res, 405, false, 'Méthode non autorisée.');
  const transportTest = process.env.MAIL_TRANSPORT === 'stream';
  if (!transportTest && (!process.env.SMTP_USER || !process.env.SMTP_PASS)) {
    return repondre(res, 503, false, 'L’envoi en ligne n’est pas encore activé.');
  }
  let donnees;
  try { donnees = await lire(req); } catch (e) { return repondre(res, 400, false, 'Demande illisible.'); }
  const { champs, fichier, tropLourd } = donnees;
  const c = (k) => champs[k] || '';

  // Anti-robots : champ caché rempli ou envoi instantané
  if (c('site_web')) return repondre(res, 200, true);
  if (Number(c('duree')) < 1500) return repondre(res, 400, false, 'Envoi trop rapide, merci de réessayer.');
  const email = c('email');
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return repondre(res, 400, false, 'Adresse e-mail invalide.');

  let message;
  if (c('type') === 'facture') {
    const nom = c('nom'), entreprise = c('entreprise'), tel = c('tel');
    if (!nom || !entreprise || !tel) return repondre(res, 400, false, 'Merci de remplir tous les champs.');
    if (c('rgpd') !== 'oui') return repondre(res, 400, false, 'Merci d’accepter l’utilisation de vos informations.');
    if (tropLourd) return repondre(res, 413, false, 'Fichier trop lourd (4 Mo maximum).');
    if (!fichier || !fichier.donnees.length) return repondre(res, 400, false, 'La facture n’a pas été reçue.');
    const t = typeFichier(fichier.donnees);
    if (!t) return repondre(res, 400, false, 'Format non pris en charge (PDF, JPG ou PNG).');
    const base = fichier.nom.replace(/\.[^.]*$/, '').replace(/[^A-Za-z0-9._-]+/g, '-').slice(0, 60).replace(/^-+|-+$/g, '') || 'facture';
    message = {
      subject: `Facture à analyser – ${entreprise}`,
      text: `Nouvelle facture à analyser, reçue via trinity-energie.fr\n\nNom : ${nom}\nEntreprise : ${entreprise}\nTéléphone : ${tel}\nE-mail : ${email}\n\nLa facture est jointe. Engagement affiché : rappel sous 48 heures ouvrées.\n`,
      attachments: [{ filename: `facture-${base}.${t.ext}`, content: fichier.donnees, contentType: t.mime }],
    };
  } else if (c('type') === 'rappel') {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(c('finContrat'));
    if (!m) return repondre(res, 400, false, 'Date de fin de contrat invalide.');
    const fin = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
    let debut = new Date(fin); debut.setMonth(debut.getMonth() - 6);
    const demain = new Date(); demain.setHours(0, 0, 0, 0); demain.setDate(demain.getDate() + 1);
    if (debut < demain) debut = demain;
    const lendemain = new Date(debut); lendemain.setDate(lendemain.getDate() + 1);
    const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
    const ics = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Trinity Energie//Site//FR', 'METHOD:PUBLISH', 'BEGIN:VEVENT',
      `UID:${Date.now().toString(36)}${Math.random().toString(36).slice(2)}@trinity-energie.fr`, `DTSTAMP:${stamp}`,
      `DTSTART;VALUE=DATE:${ymd(debut)}`, `DTEND;VALUE=DATE:${ymd(lendemain)}`,
      `SUMMARY:Relancer ${email} (fin de contrat le ${frDate(fin)})`,
      `DESCRIPTION:Demande de rappel reçue via le site. Contact : ${email}`, 'END:VEVENT', 'END:VCALENDAR', ''].join('\r\n');
    message = {
      subject: `Rappel d’échéance – fin de contrat le ${frDate(fin)}`,
      text: `Demande de rappel d'échéance, reçue via trinity-energie.fr\n\nE-mail : ${email}\nFin de contrat : ${frDate(fin)}\nÀ recontacter à partir du : ${frDate(debut)}\n\nLe site a promis au client un e-mail à cette date. Un rendez-vous agenda est joint.\n`,
      attachments: [{ filename: 'rappel-trinity.ics', content: ics, contentType: 'text/calendar; charset=UTF-8; method=PUBLISH' }],
    };
  } else {
    return repondre(res, 400, false, 'Demande inconnue.');
  }

  const transport = transportTest
    ? nodemailer.createTransport({ streamTransport: true, buffer: true })
    : nodemailer.createTransport({
        host: process.env.SMTP_HOST || 'smtp.hostinger.com',
        port: Number(process.env.SMTP_PORT || 465),
        secure: String(process.env.SMTP_PORT || 465) === '465',
        auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS },
      });
  try {
    const info = await transport.sendMail({
      from: { name: 'Site Trinity Énergie', address: process.env.SMTP_USER || DESTINATAIRE },
      to: DESTINATAIRE, replyTo: email, ...message,
    });
    if (transportTest) res.setHeader('X-Test-Taille', String(info.message.length));
  } catch (e) {
    console.error('Envoi impossible :', e && e.message);
    return repondre(res, 502, false, 'L’e-mail n’a pas pu partir.');
  }
  return repondre(res, 200, true);
};
