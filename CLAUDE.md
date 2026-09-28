# Standard de design à respecter

Le client a validé le design « liquid glass » du site Trinity Énergie (`trinity-energie/index.html`).
C'est le niveau attendu pour tout travail dans ce dépôt : épuré, sombre, précis, dans l'esprit d'Apple.

## Principes
- Beaucoup d'air, peu d'éléments, une seule audace par écran. Tout doit rester compact, surtout sur mobile.
- Verre dépoli sur les éléments flottants (barre de navigation en pilule, sélecteurs, pastilles, barre d'action mobile, cartes d'avis) :
  fond `rgba(255,255,255,.06–.085)`, bordure 1px `rgba(255,255,255,.10–.14)`, reflet intérieur `inset 0 1px 0 rgba(255,255,255,.12–.20)`,
  `backdrop-filter: blur(20–28px) saturate(1.7)`, avec un repli `@supports not (backdrop-filter…)`.
- Grands panneaux (formulaires, bandeaux) : fond presque uni `rgba(255,255,255,.028)`, bordure `.09`, **sans dégradé clair en haut**
  (le client a refusé ce « reflet » sur les grands panneaux).
- Lumière ambiante : halos bleus flous et fixes derrière la page (`body::before`), que le verre laisse deviner.
- Boutons en pilule : primaire bleu avec reflet intérieur et ombre colorée, secondaire en verre.
- Coins très arrondis : 28–40 px pour les panneaux et cartes, 999 px pour les pilules.

## Typographie et couleurs (plaquette Trinity)
- Titres : Sora 600–700, casse normale, lettres serrées (-0,03 à -0,045 em), `text-wrap: balance`.
  Titre principal sur deux lignes nettes sur ordinateur (une ligne par bloc, `white-space: nowrap`), seconde ligne en dégradé bleu.
- Texte : Manrope. Hiérarchie par gris-bleus translucides (`--text` .78, `--muted` .52, `--faint` .34).
- Fond `#03081A`, marine `#0A1F4A`, bleu `#1F5FFF`, bleu vif `#3C8BFF`, glace `#DCE5F7` / `#9DB4E4`, étoiles `#FFCF5C`, erreur `#FF8A80`.

## Interactions
- Animations sobres (`cubic-bezier(.22,.8,.12,1)`), toujours respecter `prefers-reduced-motion`.
- Sélecteur à curseur glissant plutôt que deux blocs côte à côte ; un seul panneau affiché à la fois.
- Progression liée au défilement (rail qui se remplit, étapes qui s'allument).
- Tout le contenu reste lisible au repos (jamais `opacity: 0` en attente d'un observer).

## À éviter (retours du client)
- Triangles ou flèches vers le haut comme puces (on lit « les prix montent ») : utiliser des points neutres.
- Sections, listes ou chiffres géants décoratifs qui n'apportent rien ; halos flous dans les petits blocs.
- Phrases ambiguës : préférer des faits clairs, ou rien.
- Cacher l'élément vedette (l'éolienne de l'en-tête) derrière le texte ou un voile trop sombre.

## Mobile et iPhone
- Champs en 16 px (pas de zoom Safari), `autocomplete`, `inputmode`, `enterkeyhint` ; marges `safe-area-inset`.
- Barre d'action flottante en verre ; sections resserrées ; vérifier à 390 px de large.
- Vérifier chaque changement en capture (ordinateur 1366–1440 px et iPhone 14) avant de publier.

## Site Trinity Énergie
- Dossier `trinity-energie/` : `index.html` autonome ; `envoi.php` (Hostinger) et `api/envoi.js` (Vercel, SMTP) pour les formulaires.
- En-tête : éolienne 3D (three.js r128, fichier `three.min.js` hébergé) avec une éolienne dessinée de secours (classe `.gl-on` quand la 3D s'affiche).
- Avis clients modifiables dans `index.html` (chercher `MODIFIER LES AVIS`). Mise en ligne décrite dans `trinity-energie/LISEZMOI.md`.
- Aperçu claude.ai : version dérivée d'`index.html` (sans doctype ni `<head>`, polices Google Fonts, three.js via cdnjs, images en data URI).
