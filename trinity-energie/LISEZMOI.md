# Site Trinity Énergie

Fichiers à mettre en ligne (dans `public_html` sur Hostinger) :

- `index.html` : la page
- `envoi.php` : envoie les formulaires (facture et rappel) par e-mail à pierrelouis@trinity-energie.fr
- `fonts/` : les polices de la plaquette (Sora et Manrope)

## Mise en ligne sur Hostinger (pas besoin de toucher aux DNS)

1. hPanel → Sites web → trinity-energie.fr → **Gestionnaire de fichiers**.
2. Ouvrir `public_html`, garder une copie de l'ancien `index.html` (le renommer `index-ancien.html`).
3. Envoyer `index.html`, `envoi.php` et le dossier `fonts` (remplacer si demandé).
4. Tester : envoyer une vraie facture depuis le site et vérifier la boîte pierrelouis@trinity-energie.fr (et les spams).

Si un `index.php` (WordPress) est présent, il passe avant `index.html` : le renommer.

## Modifier les avis clients

Dans `index.html`, chercher `MODIFIER LES AVIS` : chaque avis est un bloc `<figure class="review">…</figure>`.
Dans le Gestionnaire de fichiers, clic droit sur `index.html` → Modifier, changer le texte, enregistrer.
