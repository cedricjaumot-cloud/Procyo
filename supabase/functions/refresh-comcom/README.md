# Edge Function : refresh-comcom

Rafraîchissement **manuel** des données Odoo, déclenché par le bouton
« 🔄 Recharger depuis Odoo » du dashboard.

Flux : `bouton → cette fonction → Odoo (JSON-RPC) → Supabase`, et la fonction
renvoie les données fraîches dans la réponse (le dashboard se met à jour
immédiatement, sans attente).

Elle remplace l'ancien système GitHub Actions + cron (déclenché de façon
irrégulière par GitHub).

---

## Déploiement (à faire une seule fois)

### 1. Installer le Supabase CLI

- Windows (PowerShell, via Scoop) :
  ```powershell
  scoop install supabase
  ```
  (ou télécharger le binaire : https://github.com/supabase/cli/releases)

### 2. Se connecter et lier le projet

```bash
supabase login
supabase link --project-ref rzeequxjvsoqvbetxmev
```
(`rzeequxjvsoqvbetxmev` = ta référence de projet, visible dans l'URL Supabase.)

### 3. Définir les secrets Odoo

Ce sont les mêmes valeurs que tes GitHub Secrets actuels :

```bash
supabase secrets set ODOO_URL="https://ton-odoo.exemple.com"
supabase secrets set ODOO_DB="nom_de_la_base"
supabase secrets set ODOO_USERNAME="ton_user_odoo"
supabase secrets set ODOO_PASSWORD="ton_mot_de_passe_odoo"
```

> `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` et `SUPABASE_ANON_KEY` sont
> fournis automatiquement par Supabase — **ne pas** les définir à la main.

### 4. Déployer

```bash
supabase functions deploy refresh-comcom
```

---

## Tester en local (optionnel)

```bash
supabase functions serve refresh-comcom --env-file supabase/.env.local
```
avec un fichier `supabase/.env.local` contenant les 4 secrets Odoo + les
clés Supabase. (Ne pas committer ce fichier.)

---

## Notes

- Le contrôle d'accès réutilise la fonction `get_comcom_data` : seul un
  admin valide (même login que le dashboard) peut déclencher la synchro.
- L'ancien workflow GitHub Actions (`.github/workflows/comcom-sync.yml`) a
  son cron désactivé. Le script Python reste disponible en secours (lançable
  manuellement depuis l'onglet Actions).
