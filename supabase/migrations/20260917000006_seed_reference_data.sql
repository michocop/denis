-- Energy Courtage — reference data.
-- Stage labels, banner copy and comment templates are transcribed from the
-- source app so the clone speaks in exactly the same voice.
-- {filleul}, {parrain} and {montant} are interpolated by render_template().

insert into stages (key, label, position, is_reward_trigger, is_terminal, banner_template, comment_template) values
('a_contacter', 'À contacter', 1, false, false,
 null,
 E'Merci pour la mise en relation. Nous avons bien reçu les coordonnées de {filleul}. Prochain point après le 1er échange.'),

('rdv_programme', 'RDV programmé', 2, false, false,
 null,
 E'J''ai contacté {filleul}. Le rendez-vous est planifié. Je vous tiens informé(e) de la suite.'),

('proposition_envoyee', 'Proposition envoyée', 3, false, false,
 null,
 E'J''ai transmis à {filleul} la proposition. Retour attendu très prochainement.'),

-- The 🎁 Récompense badge is pinned to this stage in the UI.
('devis_signe', 'Devis signé', 4, true, false,
 E'Contrat signé. Disponible dans l''onglet Documents',
 -- TODO: the real template for this stage has not been seen in a screenshot yet.
 E'{filleul} a signé le devis. Votre récompense est validée, nous revenons vers vous pour le règlement.'),

('mission_terminee', 'Mission terminée', 5, false, true,
 E'Contrat signé. Disponible dans l''onglet Documents',
 E'Bonjour {parrain},\nJe vous informe que nous allons procéder au paiement de vos honoraires. Vous recevrez votre gain très prochainement.\nN''oubliez pas de procéder à votre déclaration de revenu en fin d''année.\nSi vous êtes un apporteur d''affaire occasionnel, vous devez déclarer les sommes perçues au titre des bénéfices non commerciaux (BNC) via votre déclaration de revenus - CERFA 2042 C -\nBonne journée.');
