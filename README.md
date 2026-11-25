# Boutique LMSTT

Caisse, stocks et bilan de saison de la boutique du Le Mans Sarthe Tennis de Table.

- **Page** : `index.html`, publiée par GitHub Pages.
- **Données** : projet Supabase « Gestion » (tables `catalogue`, `ventes`, `entrees`, `ajustements`, `parametres`).
- **Accès** : code PIN (vendeur ou admin). Aucune donnée n'est lisible sans PIN ; tout passe par les fonctions `api_*`.
- **Saison sportive** : du 1er août au 31 juillet.
- **Réveil automatique** : `.github/workflows/reveil-supabase.yml` interroge la base tous les 3 jours pour éviter la mise en pause du projet gratuit.

La clé Supabase présente dans le code est une clé *publishable* (publique par conception) : elle ne donne accès qu'aux fonctions protégées par PIN.
