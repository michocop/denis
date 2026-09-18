-- Energy Courtage — reference data.
-- Stage labels, banner copy and comment templates are transcribed from the
-- source app so the clone speaks in exactly the same voice.
-- {filleul}, {parrain} and {montant} are interpolated by render_template().

insert into stages (key, label, position, is_reward_trigger, is_terminal, banner_template, comment_template) values
('a_contacter', 'À contacter', 1, false, false,
 null,
 $tpl$Merci pour la mise en relation. Nous avons bien reçu les coordonnées de {filleul}. Prochain point après le 1er échange.$tpl$),

('rdv_programme', 'RDV programmé', 2, false, false,
 null,
 $tpl$J'ai contacté {filleul}. Le rendez-vous est planifié. Je vous tiens informé(e) de la suite.$tpl$),

('proposition_envoyee', 'Proposition envoyée', 3, false, false,
 null,
 $tpl$J'ai transmis à {filleul} la proposition. Retour attendu très prochainement.$tpl$),

-- The 🎁 Récompense badge is pinned to this stage in the UI.
('devis_signe', 'Devis signé', 4, true, false,
 $tpl$Contrat signé. Disponible dans l'onglet Documents$tpl$,
 -- TODO: the real template for this stage has not been seen in a screenshot yet.
 $tpl${filleul} a signé le devis. Votre récompense est validée, nous revenons vers vous pour le règlement.$tpl$),

('mission_terminee', 'Mission terminée', 5, false, true,
 $tpl$Contrat signé. Disponible dans l'onglet Documents$tpl$,
 $tpl$Bonjour {parrain},
Je vous informe que nous allons procéder au paiement de vos honoraires. Vous recevrez votre gain très prochainement.
N'oubliez pas de procéder à votre déclaration de revenu en fin d'année.
Si vous êtes un apporteur d'affaire occasionnel, vous devez déclarer les sommes perçues au titre des bénéfices non commerciaux (BNC) via votre déclaration de revenus - CERFA 2042 C -
Bonne journée.$tpl$);
