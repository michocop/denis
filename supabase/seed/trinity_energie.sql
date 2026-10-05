-- Trinity Énergie — the company's identity, and its legal texts filled in.
--
-- Data, not schema: applied to the production project once (and again after
-- any change here) with
--   supabase db query --linked -f supabase/seed/trinity_energie.sql
--
-- Source: the RNE / INSEE record (societe.com, 05/10/2026) and the company's
-- site. Values marked PROPOSITION in the texts are commercial or legal choices
-- proposed by default; the texts are inserted INACTIVE and are switched on,
-- once read and agreed, with:
--   update legal_documents set active = true where version = '2026-10-1';

-- ======================================================== the customer
-- The legal identity printed on every invoice as the client.
insert into billing_settings (legal_name, legal_form, share_capital, siren, rcs_city,
                              vat_number, address, postal_code, city, email,
                              payment_term_days)
values ('TRINITY ENERGIE', 'SAS', '1 000 €', '102470705', 'Lille Métropole',
        'FR18102470705', '945 rue du Général de Gaulle', '59310', 'Aix-en-Pévèle',
        'pierrelouis@trinity-energie.fr', 30)
on conflict (id) do update
  set legal_name = excluded.legal_name, legal_form = excluded.legal_form,
      share_capital = excluded.share_capital, siren = excluded.siren,
      rcs_city = excluded.rcs_city, vat_number = excluded.vat_number,
      address = excluded.address, postal_code = excluded.postal_code,
      city = excluded.city, email = excluded.email,
      payment_term_days = excluded.payment_term_days, updated_at = now();

-- ============================================== the self-billing mandate
insert into legal_documents (key, version, title, body, sha256, active)
values ('mandat_facturation', '2026-10-1', 'Mandat de facturation', '**Entre les soussignés :**

**TRINITY ENERGIE**, société par actions simplifiée au capital de 1 000 €, dont
le siège social est situé 945 rue du Général de Gaulle, 59310 Aix-en-Pévèle,
immatriculée au RCS de Lille Métropole sous le numéro 102 470 705, représentée
par Pierre-Louis Tettamanti, en qualité de Président,

ci-après « **le Mandataire** »,

**Et :**

l''apporteur d''affaires titulaire du compte depuis lequel le présent mandat est
signé, dont l''identité, le statut, l''adresse et le numéro SIREN sont ceux
renseignés dans son profil au jour de la signature et reproduits sur chaque
facture,

ci-après « **le Mandant** ».

## Article 1 — Objet

Le Mandant donne mandat au Mandataire d''établir, en son nom et pour son compte,
les factures correspondant aux commissions d''apport d''affaires qui lui sont
dues au titre des mises en relation qu''il réalise.

## Article 2 — Obligations du Mandataire

Le Mandataire s''engage à :

- établir les factures conformément aux mentions obligatoires prévues par
  l''article 242 nonies A de l''annexe II au CGI ;
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
  dans un délai de 8 jours à compter de sa mise à disposition ;
- conserver un double de chaque facture pendant dix ans ;
- procéder lui-même aux déclarations fiscales et sociales qui lui incombent.

## Article 4 — Régime de TVA

Le régime de TVA applicable est celui que le Mandant déclare dans son profil :
franchise en base (article 293 B du CGI) ou régime réel, avec son numéro de TVA
intracommunautaire. Il figure sur chaque facture. Tout changement de régime
doit être signalé sans délai ; les factures ultérieures seront établies en
conséquence.

## Article 5 — Absence de lien de subordination

Le Mandant exerce son activité en toute indépendance. Le présent mandat ne crée
ni lien de subordination, ni exclusivité, ni obligation de résultat.

## Article 6 — Durée et résiliation

Le présent mandat prend effet à la date de sa signature et est conclu pour une
durée indéterminée. Chaque partie peut y mettre fin à tout moment moyennant un
préavis de 30 jours notifié par écrit. Les factures établies avant la
résiliation demeurent valables.

## Article 7 — Signature électronique

Les parties conviennent que la signature électronique apposée via l''application,
confirmée le cas échéant par un code reçu par SMS, constitue une signature au
sens de l''article 1367 du Code civil et vaut preuve de leur consentement. La
date, l''heure et l''empreinte du document signé sont conservées.', '', false)
on conflict (key, version) do nothing;

-- ========================================================== the CGU
insert into legal_documents (key, version, title, body, sha256, active)
values ('cgu', '2026-10-1', 'Conditions générales d''utilisation', '## 1. Objet

Les présentes CGU régissent l''utilisation de l''application Trinity Énergie,
éditée par TRINITY ENERGIE, SAS au capital de 1 000 €, 945 rue du Général de
Gaulle, 59310 Aix-en-Pévèle, SIREN 102 470 705, permettant à des apporteurs
d''affaires de transmettre des mises en relation et d''en suivre le traitement.

## 2. Accès

L''accès est **réservé aux personnes invitées** par l''éditeur. Il n''existe pas
d''inscription libre. L''éditeur peut refuser, suspendre ou retirer un accès,
notamment en cas de manquement aux présentes.

## 3. Compte

L''utilisateur est responsable de la confidentialité de ses identifiants et des
actions effectuées depuis son compte. Toute utilisation frauduleuse doit être
signalée sans délai à pierrelouis@trinity-energie.fr.

## 4. Obligations de l''apporteur

L''apporteur s''engage à :

- ne transmettre que des coordonnées de personnes qu''il a **préalablement
  informées** et dont il a recueilli l''accord ;
- ne pas transmettre de données inexactes ou obtenues de manière illicite ;
- ne pas se présenter comme salarié, mandataire ou représentant de l''éditeur ;
- ne formuler aucune offre, aucun prix ni aucun engagement au nom de l''éditeur.

## 5. Rémunération

La rémunération est due dans les conditions suivantes :

- son montant est fixé pour chaque recommandation et affiché dans
  l''application ;
- elle est **acquise à la signature du devis** par le prospect ;
- elle est réglée par virement, sur la base d''une facture établie dans le cadre
  du mandat de facturation, dans un délai de 30 jours à compter de la signature
  de la facture par les deux parties ;
- elle n''est pas due si la personne recommandée était **déjà connue** de
  l''éditeur ou déjà suivie au titre d''une recommandation antérieure ;
- elle n''est pas due en cas d''annulation, de rétractation ou d''impayé.

Tout retard de paiement donne lieu aux pénalités prévues par l''article L441-10
du Code de commerce et à l''indemnité forfaitaire de 40 € pour frais de
recouvrement.

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

Droit français. À défaut de résolution amiable, compétence des tribunaux du
ressort de la cour d''appel de Douai.

Version du 5 octobre 2026.', '', false)
on conflict (key, version) do nothing;

-- ===================================================== the privacy policy
insert into legal_documents (key, version, title, body, sha256, active)
values ('confidentialite', '2026-10-1', 'Politique de confidentialité', '**Responsable de traitement :** TRINITY ENERGIE, SAS, 945 rue du Général de
Gaulle, 59310 Aix-en-Pévèle, SIREN 102 470 705.
**Contact :** pierrelouis@trinity-energie.fr. **Délégué à la protection des
données :** non désigné ; toute demande est traitée à l''adresse ci-dessus.

## 1. Données concernant les apporteurs

Identité (nom, prénom, email, téléphone), données professionnelles (raison
sociale, SIREN, régime de TVA), coordonnées bancaires, documents justificatifs,
historique des recommandations et des rémunérations.

**Base légale :** exécution du contrat d''apport d''affaires et obligations
légales (facturation, comptabilité).

## 2. Données concernant les prospects (« filleuls »)

Nom, prénom, téléphone, email, et le cas échéant raison sociale, adresse et
facture d''énergie, transmis par un apporteur.

**Base légale :** intérêt légitime de TRINITY ENERGIE à proposer ses services de
courtage en énergie aux personnes recommandées, l''apporteur ayant
préalablement informé la personne et recueilli son accord.

L''apporteur confirme dans l''application avoir informé la personne concernée et
recueilli son accord avant toute transmission. Cette confirmation est
horodatée et conservée.

**Information de la personne concernée :** TRINITY ENERGIE informe la personne
lors de son premier contact, et au plus tard dans un délai d''un mois, de
l''origine de ses données, des finalités du traitement et de ses droits
(article 14 du RGPD). Elle peut s''opposer à tout moment au traitement.

## 3. Destinataires

Les données sont accessibles :

- à l''apporteur, pour ses seules recommandations ;
- aux collaborateurs habilités de TRINITY ENERGIE ;
- à nos sous-traitants techniques : Supabase (hébergement, Paris, Union
  européenne), Brevo (envoi des SMS de vérification, France) et le prestataire
  d''envoi des emails ;
- le cas échéant, aux fournisseurs d''énergie sollicités, avec l''accord de la
  personne concernée.

Aucune donnée n''est vendue ni utilisée à des fins publicitaires.

## 4. Durées de conservation

| Donnée | Durée |
|---|---|
| Compte apporteur | Durée de la relation, puis 3 ans |
| Recommandation aboutie | 5 ans à compter de la fin de la prestation |
| Recommandation non aboutie | 3 ans après le dernier contact, puis anonymisation automatique |
| Factures et pièces comptables | 10 ans (obligation légale) |
| Codes SMS de vérification | 10 minutes de validité ; seule une empreinte est conservée |
| Journaux techniques | 12 mois |

## 5. Vos droits

Accès, rectification, effacement, limitation, opposition et portabilité, à
exercer auprès de pierrelouis@trinity-energie.fr. Réponse sous un mois.

Un apporteur peut exporter ses données et supprimer son compte directement dans
l''application (Profil). Les factures et les recommandations qui s''y
rattachent sont conservées au titre des obligations comptables, mais les
données personnelles du compte sont effacées.

Réclamation possible auprès de la CNIL : www.cnil.fr.

## 6. Sécurité

Chaque apporteur n''accède qu''à ses propres recommandations, restriction
appliquée au niveau de la base de données et non seulement dans l''application.
Les échanges sont chiffrés en transit. Les signatures sont confirmées par un
code à usage unique envoyé par SMS. L''accès administrateur est nominatif et
journalisé.

## 7. Modifications

Toute modification sera notifiée dans l''application. Version du 5 octobre 2026.', '', false)
on conflict (key, version) do nothing;
