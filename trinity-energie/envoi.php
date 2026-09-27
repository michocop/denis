<?php
/**
 * Trinity Énergie : réception des formulaires du site.
 *  - type=facture : facture jointe + coordonnées, envoyées par e-mail.
 *  - type=rappel  : demande de rappel d'échéance, avec un rendez-vous agenda (.ics) joint.
 * Rien n'est stocké sur le serveur.
 */

$DESTINATAIRE = 'pierrelouis@trinity-energie.fr';
$EXPEDITEUR   = 'pierrelouis@trinity-energie.fr'; // doit être une adresse du domaine
$TAILLE_MAX   = 10 * 1024 * 1024;

header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');

function repondre($code, $ok, $message = '') {
    http_response_code($code);
    echo json_encode(array('ok' => $ok, 'message' => $message), JSON_UNESCAPED_UNICODE);
    exit;
}
function champ($nom) {
    $v = isset($_POST[$nom]) ? trim((string) $_POST[$nom]) : '';
    return str_replace(array("\r", "\n", "\0"), ' ', mb_substr($v, 0, 300));
}
function entete($texte) {
    return '=?UTF-8?B?' . base64_encode($texte) . '?=';
}
function envoyer($a, $sujet, $texte, $piece, $replyTo, $de) {
    $limite = 'te_' . bin2hex(random_bytes(12));
    $h  = 'From: ' . entete('Site Trinity Énergie') . " <$de>\r\n";
    if ($replyTo) $h .= "Reply-To: $replyTo\r\n";
    $h .= "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"$limite\"\r\n";
    $corps  = "--$limite\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n";
    $corps .= chunk_split(base64_encode($texte)) . "\r\n";
    if ($piece) {
        $corps .= "--$limite\r\nContent-Type: {$piece['type']}; name=\"{$piece['nom']}\"\r\n";
        $corps .= "Content-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"{$piece['nom']}\"\r\n\r\n";
        $corps .= chunk_split(base64_encode($piece['data'])) . "\r\n";
    }
    $corps .= "--$limite--\r\n";
    $ok = @mail($a, entete($sujet), $corps, $h, '-f' . $de);
    if (!$ok) $ok = @mail($a, entete($sujet), $corps, $h);
    return $ok;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') repondre(405, false, 'Méthode non autorisée.');
// Anti-robots : champ caché rempli ou envoi instantané
if (champ('site_web') !== '') repondre(200, true);
if ((int) champ('duree') < 1500) repondre(400, false, 'Envoi trop rapide, merci de réessayer.');

$type  = champ('type');
$email = champ('email');
if (!filter_var($email, FILTER_VALIDATE_EMAIL)) repondre(400, false, 'Adresse e-mail invalide.');

if ($type === 'facture') {
    $nom = champ('nom'); $entreprise = champ('entreprise'); $tel = champ('tel');
    if ($nom === '' || $entreprise === '' || $tel === '') repondre(400, false, 'Merci de remplir tous les champs.');
    if (champ('rgpd') !== 'oui') repondre(400, false, 'Merci d’accepter l’utilisation de vos informations.');
    $f = $_FILES['facture'] ?? null;
    if (!$f || $f['error'] !== UPLOAD_ERR_OK) repondre(400, false, 'La facture n’a pas été reçue.');
    if ($f['size'] > $TAILLE_MAX) repondre(400, false, 'Fichier trop lourd (10 Mo maximum).');
    $mime = (new finfo(FILEINFO_MIME_TYPE))->file($f['tmp_name']);
    $ext  = array('application/pdf' => 'pdf', 'image/jpeg' => 'jpg', 'image/png' => 'png');
    if (!isset($ext[$mime])) repondre(400, false, 'Format non pris en charge (PDF, JPG ou PNG).');
    $base = preg_replace('/[^A-Za-z0-9._-]+/', '-', pathinfo($f['name'], PATHINFO_FILENAME));
    $piece = array('type' => $mime, 'nom' => 'facture-' . trim(substr($base, 0, 60), '-') . '.' . $ext[$mime], 'data' => file_get_contents($f['tmp_name']));
    $texte = "Nouvelle facture à analyser, reçue via trinity-energie.fr\n\n"
           . "Nom : $nom\nEntreprise : $entreprise\nTéléphone : $tel\nE-mail : $email\n\n"
           . "La facture est jointe. Engagement affiché : rappel sous 48 heures ouvrées.\n";
    $ok = envoyer($DESTINATAIRE, "Facture à analyser – $entreprise", $texte, $piece, $email, $EXPEDITEUR);
} elseif ($type === 'rappel') {
    $fin = champ('finContrat');
    $d = DateTime::createFromFormat('!Y-m-d', $fin);
    if (!$d) repondre(400, false, 'Date de fin de contrat invalide.');
    $debut = (clone $d)->modify('-6 months');
    $demain = new DateTime('tomorrow');
    if ($debut < $demain) $debut = $demain;
    $finTxt = $d->format('d/m/Y');
    $ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Trinity Energie//Site//FR\r\nMETHOD:PUBLISH\r\nBEGIN:VEVENT\r\n"
         . 'UID:' . bin2hex(random_bytes(8)) . "@trinity-energie.fr\r\nDTSTAMP:" . gmdate('Ymd\THis\Z') . "\r\n"
         . 'DTSTART;VALUE=DATE:' . $debut->format('Ymd') . "\r\nDTEND;VALUE=DATE:" . (clone $debut)->modify('+1 day')->format('Ymd') . "\r\n"
         . 'SUMMARY:Relancer ' . $email . ' (fin de contrat le ' . $finTxt . ")\r\n"
         . 'DESCRIPTION:Demande de rappel reçue via le site. Contact : ' . $email . "\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    $texte = "Demande de rappel d'échéance, reçue via trinity-energie.fr\n\n"
           . "E-mail : $email\nFin de contrat : $finTxt\nÀ recontacter à partir du : " . $debut->format('d/m/Y') . "\n\n"
           . "Le site a promis au client un e-mail à cette date. Un rendez-vous agenda est joint.\n";
    $ok = envoyer($DESTINATAIRE, "Rappel d’échéance – fin de contrat le $finTxt", $texte,
                  array('type' => 'text/calendar; charset=UTF-8; method=PUBLISH', 'nom' => 'rappel-trinity.ics', 'data' => $ics), $email, $EXPEDITEUR);
} else {
    repondre(400, false, 'Demande inconnue.');
}

if (!$ok) repondre(500, false, 'L’e-mail n’a pas pu partir.');
repondre(200, true);
