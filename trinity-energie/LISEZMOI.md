# Site Trinity Énergie

Fichiers à mettre en ligne dans `public_html` sur Hostinger (tous au même niveau) :

| Fichier | Rôle |
|---|---|
| `index.html` | la page |
| `envoi.php` | envoie les formulaires (facture et rappel) par e-mail à pierrelouis@trinity-energie.fr |
| `fonts/` (dossier) | les polices de la plaquette (Sora et Manrope) |
| `pierre-louis.webp`, `pierre-louis.png` | le portrait de la section « Votre interlocuteur » |
| `plaquette-apporteurs-affaires.pdf` | la plaquette téléchargeable (section Partenaires) |
| `og-image.jpg` | l'image qui s'affiche quand on partage le lien (WhatsApp, SMS, LinkedIn) |
| `apple-touch-icon.png` | l'icône quand on ajoute le site à l'écran d'accueil de l'iPhone |
| `three.min.js` | la bibliothèque qui anime l'éolienne en 3D (sans elle, une éolienne dessinée s'affiche) |

## Mise en ligne sur Hostinger (pas besoin de toucher aux DNS)

1. hPanel → Sites web → trinity-energie.fr → **Gestionnaire de fichiers**.
2. Ouvrir `public_html`, garder une copie de l'ancien `index.html` (le renommer `index-ancien.html`).
3. Envoyer tous les fichiers du tableau (remplacer si demandé).
4. Tester : envoyer une vraie facture depuis le site et vérifier la boîte pierrelouis@trinity-energie.fr (et les spams).

Si un `index.php` (WordPress) est présent, il passe avant `index.html` : le renommer.

## À compléter dans `index.html`

- **Liens Google** : chercher `google.com/maps/search` (3 endroits) et remplacer par le lien exact de la fiche
  (Google Maps → la fiche → Partager → Copier le lien). Pour le bouton « Laisser un avis », utiliser le lien
  « Demander des avis » de la fiche d'établissement Google.
- **Note Google** : « 5,0 » est la moyenne actuelle ; la mettre à jour si elle change (chercher `5,0`).

## Modifier les avis clients

Dans `index.html`, chercher `MODIFIER LES AVIS` : chaque avis est un bloc `<figure class="review">…</figure>`.
Dans le Gestionnaire de fichiers, clic droit sur `index.html` → Modifier, changer le texte, enregistrer.
