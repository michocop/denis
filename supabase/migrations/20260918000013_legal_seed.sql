-- Energy Courtage — the legal texts, as data.
--
-- Seeded INACTIVE on purpose. Every one still carries [PLACEHOLDERS] the
-- client has to fill (company name, SIREN, notice periods) and none has been
-- through a lawyer. The publish trigger refuses to activate a document that
-- still contains one, so the app cannot ask anybody to sign "[RAISON SOCIALE]".
--
-- To go live: fill the placeholders, have a lawyer read it, then
--   update legal_documents set active = true where key = '...' and version = '...';
-- which will fail loudly if anything was missed.


insert into legal_documents (key, version, title, body, sha256, active)
values ('mandat_facturation', '2026-09-1', 'Mandat de facturation', '**Entre les soussignés :**

**[RAISON SOCIALE]**, [forme juridique] au capital de [montant] €, dont le siège
social est situé [adresse], immatriculée au RCS de [ville] sous le numéro
[SIREN], représentée par [nom], en qualité de [qualité],

ci-après « **le Mandataire** »,

**Et :**

[Prénom NOM], [statut : micro-entrepreneur / société], demeurant [adresse],
immatriculé sous le numéro SIREN [SIREN],

ci-après « **le Mandant** ».

## Article 1 — Objet

Le Mandant donne mandat au Mandataire d''établir, en son nom et pour son compte,
les factures correspondant aux commissions d''apport d''affaires qui lui sont
dues au titre des mises en relation qu''il réalise.

## Article 2 — Obligations du Mandataire

Le Mandataire s''engage à :

- établir les factures conformément aux mentions obligatoires prévues par les
  articles 242 nonies A de l''annexe II au CGI ;
- respecter une numérotation chronologique et continue ;
- mettre chaque facture à disposition du Mandant préalablement à son émission
  définitive, par l''intermédiaire de l''application ;
- conserver un double de chaque facture pendant dix ans ;
- reverser au Mandant les sommes dues selon les modalités convenues.

## Article 3 — Obligations du Mandant

Le Mandant s''engage à :

- signaler sans délai au Mandataire tout changement de sa situation, notamment
  le passage à un régime assujetti à la TVA ;
- vérifier chaque facture établie en son nom et signaler toute contestation
  dans un délai de [X] jours ;
- conserver un double de chaque facture pendant dix ans ;
- procéder lui-même aux déclarations fiscales et sociales qui lui incombent.

## Article 4 — Régime de TVA

Le Mandant déclare relever, à la date de signature :

☐ du régime de la franchise en base de TVA (article 293 B du CGI)
☐ du régime réel, TVA au taux de [X] %, n° de TVA intracommunautaire [numéro]

Tout changement de régime doit être signalé sans délai ; les factures
ultérieures seront établies en conséquence.

## Article 5 — Absence de lien de subordination

Le Mandant exerce son activité en toute indépendance. Le présent mandat ne crée
ni lien de subordination, ni exclusivité, ni obligation de résultat.

## Article 6 — Durée et résiliation

Le présent mandat prend effet à la date de sa signature et est conclu pour une
durée indéterminée. Chaque partie peut y mettre fin à tout moment moyennant un
préavis de [X] jours notifié par écrit. Les factures établies avant la
résiliation demeurent valables.

## Article 7 — Signature électronique

Les parties conviennent que la signature électronique apposée via l''application
constitue une signature au sens de l''article 1367 du Code civil et vaut preuve
de leur consentement.

Fait à ................................, le ........................

**Le Mandant**                          **Le Mandataire**', '', false)
on conflict (key, version) do nothing;


insert into legal_documents (key, version, title, body, sha256, active)
values ('cgu', '2026-09-1', 'Conditions générales d''utilisation', '## 1. Objet

Les présentes CGU régissent l''utilisation de l''application [NOM], éditée par
[RAISON SOCIALE], [adresse], [SIREN], permettant à des apporteurs d''affaires de
transmettre des mises en relation et d''en suivre le traitement.

## 2. Accès

L''accès est **réservé aux personnes invitées** par l''éditeur. Il n''existe pas
d''inscription libre. L''éditeur peut refuser, suspendre ou retirer un accès,
notamment en cas de manquement aux présentes.

## 3. Compte

L''utilisateur est responsable de la confidentialité de ses identifiants et des
actions effectuées depuis son compte. Toute utilisation frauduleuse doit être
signalée sans délai à [email].

## 4. Obligations de l''apporteur

L''apporteur s''engage à :

- n''transmettre que des coordonnées de personnes qu''il a **préalablement
  informées** et dont il a recueilli l''accord ;
- ne pas transmettre de données inexactes ou obtenues de manière illicite ;
- ne pas se présenter comme salarié, mandataire ou représentant de l''éditeur ;
- ne formuler aucune offre, aucun prix ni aucun engagement au nom de l''éditeur.

## 5. Rémunération

La rémunération est due dans les conditions convenues, et notamment :

- elle est **acquise à la signature du devis** par le prospect ;
- elle est réglée après [CONDITION — ex. réalisation de la prestation], sur la
  base d''une facture établie dans le cadre du mandat de facturation ;
- elle n''est pas due si la personne recommandée était **déjà connue** de
  l''éditeur ou déjà suivie au titre d''une recommandation antérieure ;
- elle n''est pas due en cas d''annulation, de rétractation ou d''impayé.

[À VALIDER : montant, mode de calcul, délai de règlement, pénalités de retard.]

## 6. Absence d''exclusivité et de subordination

L''apporteur agit en toute indépendance. Les présentes ne créent ni contrat de
travail, ni mandat de représentation, ni exclusivité de part et d''autre.

## 7. Disponibilité

L''éditeur s''efforce d''assurer la disponibilité du service sans y être tenu, et
peut l''interrompre pour maintenance. Aucune garantie de résultat commercial
n''est donnée.

## 8. Propriété intellectuelle

L''application, sa structure et ses contenus demeurent la propriété de
l''éditeur. Aucune reproduction n''est autorisée sans accord écrit.

## 9. Responsabilité

L''éditeur ne peut être tenu responsable des conséquences d''informations
inexactes transmises par un apporteur, ni du refus d''un prospect de contracter.

## 10. Données personnelles

Voir la politique de confidentialité.

## 11. Droit applicable

Droit français. À défaut de résolution amiable, compétence des tribunaux de
[VILLE].

Version du [DATE].', '', false)
on conflict (key, version) do nothing;


insert into legal_documents (key, version, title, body, sha256, active)
values ('confidentialite', '2026-09-1', 'Politique de confidentialité', '**Responsable de traitement :** [RAISON SOCIALE], [adresse], [SIREN].
**Contact :** [email]. **Délégué à la protection des données :** [le cas échéant].

## 1. Données concernant les apporteurs

Identité (nom, prénom, email, téléphone), données professionnelles (raison
sociale, SIREN, régime de TVA), coordonnées bancaires, documents justificatifs,
historique des recommandations et des rémunérations.

**Base légale :** exécution du contrat d''apport d''affaires et obligations
légales (facturation, comptabilité).

## 2. Données concernant les prospects (« filleuls »)

Nom, prénom, téléphone, email, et le cas échéant raison sociale et adresse,
transmis par un apporteur.

**Base légale :** [À VALIDER AVEC LE CONSEIL — consentement de la personne
recueilli par l''apporteur, ou intérêt légitime assorti d''une information].

L''apporteur confirme dans l''application avoir informé la personne concernée et
recueilli son accord avant toute transmission. Cette confirmation est
horodatée et conservée.

**Information de la personne concernée :** [DÉCRIRE — qui informe le prospect,
sous quel délai, par quel moyen].

## 3. Destinataires

Les données sont accessibles :

- à l''apporteur, pour ses seules recommandations ;
- aux collaborateurs habilités de [RAISON SOCIALE] ;
- à notre hébergeur, Supabase, en qualité de sous-traitant, dans l''Union
  européenne ([RÉGION À CONFIRMER]) ;
- le cas échéant, aux fournisseurs d''énergie sollicités, avec l''accord de la
  personne concernée.

Aucune donnée n''est vendue ni utilisée à des fins publicitaires.

## 4. Durées de conservation

| Donnée | Durée |
|---|---|
| Compte apporteur | Durée de la relation, puis [X] |
| Recommandation aboutie | [X] ans à compter de la fin de la prestation |
| Recommandation non aboutie | **[À DÉFINIR — 3 ans après le dernier contact est l''usage]** |
| Factures et pièces comptables | 10 ans (obligation légale) |
| Journaux techniques | [X] mois |

## 5. Vos droits

Accès, rectification, effacement, limitation, opposition et portabilité, à
exercer auprès de [email]. Réponse sous un mois.

Un apporteur peut supprimer son compte directement dans l''application
(Profil → Supprimer mon compte). Les factures et les recommandations qui s''y
rattachent sont conservées au titre des obligations comptables, mais les
données personnelles du compte sont effacées.

Réclamation possible auprès de la CNIL : www.cnil.fr.

## 6. Sécurité

Chaque apporteur n''accède qu''à ses propres recommandations, restriction
appliquée au niveau de la base de données et non seulement dans l''application.
Les échanges sont chiffrés en transit. Les coordonnées bancaires sont chiffrées
au repos. L''accès administrateur est nominatif et journalisé.

## 7. Modifications

Toute modification sera notifiée dans l''application. Version du [DATE].', '', false)
on conflict (key, version) do nothing;
