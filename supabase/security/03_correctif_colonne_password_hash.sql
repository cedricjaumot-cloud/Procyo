-- =============================================================================
-- CORRECTIF (25/11/2026, appliqué) — à garder tant que les Edge Functions
-- broker-intake et remise-dans-le-flux écrivent encore password_hash = 'PENDING'.
-- La colonne est vide/inutilisée : le mot de passe est dans broker_secrets
-- (et app_public_broker la retire des réponses).
-- Quand ces deux fonctions ne l'écrivent plus : alter table brokers drop column password_hash;
-- =============================================================================
alter table public.brokers add column if not exists password_hash text;
notify pgrst, 'reload schema';
