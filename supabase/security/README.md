# Sécurité des connexions — procédure de mise en place

Avant : le mot de passe était comparé **dans le navigateur**, et les tables
`brokers`, `answers`, `observations` et `groupements` étaient ouvertes à tous
(règles RLS `using (true)`).

Après : le mot de passe est vérifié **par Supabase** (bcrypt), le navigateur ne
garde qu'un jeton de session (30 jours) envoyé dans l'en-tête `x-procyo-token`,
et les règles RLS n'autorisent que :

| Table | Courtier connecté | Admin | Non connecté |
|---|---|---|---|
| brokers | sa fiche | tout | rien |
| answers / observations | les siennes | tout | rien |
| groupements | lecture | tout | rien |
| broker_secrets / app_sessions | rien | rien | rien |

## Ordre à respecter

1. **Phase A** — `01_phase_A_preparation.sql` dans le SQL Editor.
   Ne casse rien : les apps actuelles continuent de fonctionner.
2. **Front** — fusionner la PR « sécurité » (Launchpad, Pricing, Workflow, Codis).
   Tout le monde devra se reconnecter une fois (avec son mot de passe habituel).
3. **Tests** — connexion sur les 4 apps, sauvegarde d'une réponse, écran Admin,
   lien d'invitation, réinitialisation de mot de passe, bouton « Recharger » de Codis.
4. **Phase C** — `02_phase_C_verrouillage.sql` : ferme les tables.
5. En cas de problème après la phase C : `99_rollback.sql`.

## Points connus

- La phase C supprimait `brokers.password_hash`, mais les Edge Functions
  `broker-intake` et `remise-dans-le-flux` y écrivent encore `'PENDING'` :
  colonne remise (vide) par `03_correctif_colonne_password_hash.sql`.
  À retirer de ces fonctions, puis supprimer la colonne.
- `send-reminders` lit des colonnes inexistantes (`M1_status`…) : les rappels ne
  partent jamais (bug antérieur, colonnes réelles `module1_status`, `m1_unlocked_at`…).

- Les mots de passe existants restent valables : ils sont convertis en bcrypt à
  la première connexion.
- Phase C supprime `trigger_comcom_refresh` (non utilisée) qui contenait un jeton
  GitHub en clair → révoquer ce jeton sur GitHub.
- Hors périmètre : les Edge Functions `send-notification` et `send-pdf-odoo`
  restent appelables sans session (à protéger dans un second temps).
