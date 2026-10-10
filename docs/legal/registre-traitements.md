# Registre des activités de traitement

> Article 30 du RGPD. Document interne, non publié : il se tient à jour et se
> présente à la CNIL sur demande. Établi d'après ce que l'application fait
> réellement (base de données, fonctions serveur), au 5 octobre 2026.
> Les valeurs marquées **PROPOSITION** sont des choix proposés par défaut ;
> celles marquées **À VALIDER** sont des questions pour l'avocat.

**Responsable de traitement :** TRINITY ENERGIE, SAS au capital de 1 000 €,
945 rue du Général de Gaulle, 59310 Aix-en-Pévèle — SIREN 102 470 705,
RCS Lille Métropole.
**Représentant et contact :** Pierre-Louis Tettamanti, pierrelouis@trinity-energie.fr
**Délégué à la protection des données :** non désigné (non obligatoire : pas de
suivi à grande échelle ni de données sensibles).

---

## Traitement n° 1 — Gestion des apporteurs d'affaires

| | |
|---|---|
| Finalité | Gérer la relation d'apport d'affaires : invitation, validation du compte, accès à l'application, suivi des recommandations et des commissions |
| Base légale | Exécution du contrat d'apport d'affaires |
| Personnes concernées | Apporteurs d'affaires (sur invitation uniquement : pas d'inscription libre) |
| Données | Identité (nom, prénom), email, téléphone mobile (vérifié par code SMS), adresse, raison sociale, SIREN, régime de TVA, coordonnées bancaires (chiffrées au repos), historique des recommandations et des commissions |
| Destinataires | Administrateurs habilités de TRINITY ENERGIE ; sous-traitants : Supabase, Brevo (voir tableau) |
| Transferts hors UE | Non |
| Conservation | Durée de la relation, puis 3 ans ; l'apporteur peut exporter ses données et supprimer son compte depuis l'application |
| Sécurité | Cloisonnement par personne appliqué en base de données (RLS), pas seulement dans l'application ; chiffrement en transit ; coordonnées bancaires chiffrées ; comptes administrateurs nominatifs et journalisés |

## Traitement n° 2 — Gestion des prospects recommandés (« filleuls »)

| | |
|---|---|
| Finalité | Traiter une mise en relation en vue d'une prestation de courtage en énergie |
| Base légale | Intérêt légitime de TRINITY ENERGIE (art. 6.1.f) — **À VALIDER** face au consentement |
| Personnes concernées | Prospects transmis par un apporteur ; ils n'ont pas de compte |
| Données | Nom, prénom, téléphone, email ; le cas échéant raison sociale, adresse, facture d'énergie et documents joints au dossier |
| Source | L'apporteur, qui confirme dans l'application avoir informé la personne et recueilli son accord (confirmation horodatée et conservée) |
| Information (art. 14) | Par TRINITY ENERGIE au premier contact, au plus tard sous un mois |
| Destinataires | Administrateurs habilités ; l'apporteur à l'origine de la recommandation (pour ses seuls dossiers) ; le cas échéant les fournisseurs d'énergie sollicités, avec l'accord de la personne ; sous-traitants : Supabase, Brevo, Apple |
| Transferts hors UE | Possible via Apple : le titre et le texte d'une notification push (nom du filleul, étape du dossier) transitent par ses serveurs — **À VALIDER** : encadrement du transfert |
| Conservation | Dossier non abouti : 36 mois après le dernier contact, puis anonymisation automatique (purge mensuelle ; durée réglable de 6 à 120 mois). Dossier abouti : 5 ans après la fin de la prestation |
| Droits | Opposition à tout moment ; effacement et export traités par un administrateur (fonctions prévues dans l'application) |

## Traitement n° 3 — Auto-facturation et paiement des commissions

| | |
|---|---|
| Finalité | Émettre, au nom et pour le compte de l'apporteur, les factures de commission (mandat d'auto-facturation, art. 289 I-2 du CGI), les faire signer et les régler |
| Base légale | Obligation légale (facturation, comptabilité) ; exécution du contrat |
| Personnes concernées | Apporteurs d'affaires |
| Données | Identité, SIREN, régime de TVA, adresse de facturation, montants, coordonnées bancaires ; signatures électroniques et leurs preuves : horodatage, adresse IP, navigateur/appareil, empreinte SHA-256 du document, vérification par code SMS ; acceptation du mandat (version et empreinte du texte accepté) |
| Destinataires | Administrateurs habilités ; expert-comptable ; administration fiscale sur demande ; sous-traitants : Supabase, Brevo (envoi du PDF signé) |
| Transferts hors UE | Non |
| Conservation | Factures et preuves de signature : 10 ans (art. L123-22 du Code de commerce). Acceptations du mandat : **PROPOSITION** 10 ans après la dernière facture émise sous ce mandat — l'application les conserve aujourd'hui sans limite, à aligner |
| Sécurité | Une facture signée ne peut être ni modifiée ni supprimée (règle en base) ; une correction passe par un avoir |

## Traitement n° 4 — Messagerie et assistance

| | |
|---|---|
| Finalité | Échanger avec les apporteurs et traiter leurs demandes d'assistance |
| Base légale | Exécution du contrat ; intérêt légitime (qualité du service) |
| Personnes concernées | Apporteurs ; administrateurs |
| Données | Contenu des messages, participants, horodatage, statut de lecture |
| Destinataires | Participants à la conversation ; sous-traitants : Supabase, Apple (aperçu du message dans la notification) |
| Transferts hors UE | Possible via Apple (aperçu de la notification) |
| Conservation | **PROPOSITION** : durée de la relation, puis 3 ans |

## Traitement n° 5 — Notifications et codes de vérification

| | |
|---|---|
| Finalité | Prévenir chacun de ce qui le concerne (dossier qui avance, facture à signer, paiement, message, compte validé) ; vérifier un numéro de mobile et confirmer une signature par code SMS |
| Base légale | Exécution du contrat ; intérêt légitime (sécurité des signatures) |
| Personnes concernées | Apporteurs ; administrateurs |
| Données | Identifiant d'appareil iOS (jeton de notification), contenu des notifications, adresse email, numéro de mobile ; codes SMS : seule une empreinte est conservée |
| Destinataires | Apple (notifications push), Brevo (emails et SMS) |
| Transferts hors UE | Possible via Apple |
| Conservation | Jeton d'appareil : jusqu'à la déconnexion ou la désinstallation ; codes SMS : 10 minutes de validité ; notifications : **PROPOSITION** 12 mois. Chacun peut couper les emails de notification dans son profil |

## Traitement n° 6 — Sécurité, preuve et continuité

| | |
|---|---|
| Finalité | Tracer les actions sensibles, diagnostiquer les incidents, restaurer les données en cas de perte |
| Base légale | Intérêt légitime ; obligation de sécurité (art. 32) |
| Données | Journal d'audit (qui a fait quoi, quand), journaux techniques, sauvegardes de la base |
| Destinataires | Administrateurs habilités ; Supabase ; GitHub (sauvegardes chiffrées) |
| Transferts hors UE | Sauvegardes : chiffrées (GPG, phrase secrète détenue par TRINITY ENERGIE) avant d'être déposées chez GitHub, qui ne peut pas les lire |
| Conservation | Journaux techniques : 12 mois ; sauvegardes : 90 jours (rotation automatique) |

---

## Sous-traitants

| Sous-traitant | Rôle | Localisation | Contrat de sous-traitance (art. 28) |
|---|---|---|---|
| Supabase Inc. | Base de données, authentification, fichiers, fonctions serveur | Paris (AWS eu-west-3), Union européenne | DPA intégré aux conditions de Supabase, accepté à la création du compte : [supabase.com/legal/dpa](https://supabase.com/legal/dpa). Un exemplaire signé peut être demandé à privacy@supabase.com |
| Brevo (Sendinblue SAS) | Emails transactionnels et SMS | France, Union européenne | DPA intégré aux conditions de Brevo, accepté à l'ouverture du compte : [brevo.com/legal/termsofuse](https://www.brevo.com/legal/termsofuse/) |
| Apple Inc. | Acheminement des notifications push (APNs) | États-Unis | Apple Developer Program License Agreement — **À VALIDER** : qualification (sous-traitant ou destinataire) et encadrement du transfert |
| GitHub Inc. | Exécution et stockage des sauvegardes nocturnes, chiffrées avant envoi | États-Unis | Conditions GitHub (DPA Microsoft) ; données illisibles sans la phrase secrète |

## Mesures de sécurité communes

- Accès aux données limité par personne directement en base (Row Level Security), testé automatiquement à chaque modification (plus de 400 vérifications).
- Chiffrement de tous les échanges (HTTPS) ; coordonnées bancaires chiffrées au repos.
- Pas d'inscription libre : un compte n'existe que sur invitation d'un administrateur.
- Signatures confirmées par code à usage unique envoyé par SMS ; preuve de signature (empreinte, horodatage, IP) conservée avec la facture.
- Clés et secrets des services tiers stockés côté serveur uniquement, jamais dans l'application.
- Purge automatique mensuelle des prospects arrivés au terme de leur durée de conservation.

## Tenue du registre

À mettre à jour à chaque nouveau traitement, nouveau sous-traitant ou changement
de durée. Dernière mise à jour : 5 octobre 2026.
