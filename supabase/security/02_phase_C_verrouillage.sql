-- =============================================================================
-- SÉCURITÉ — PHASE C : verrouillage
-- -----------------------------------------------------------------------------
-- À exécuter SEULEMENT quand le nouveau front est en ligne ET testé
-- (connexion Launchpad, Pricing, Workflow, Codis).
-- Retour arrière possible : 99_rollback.sql
-- =============================================================================

-- ── 1. Remplacer les règles « ouvertes à tous » ─────────────────────────────
drop policy if exists brokers_open     on public.brokers;
drop policy if exists answers_open     on public.answers;
drop policy if exists obs_open         on public.observations;
drop policy if exists groupements_all  on public.groupements;

-- brokers : chacun voit / modifie sa fiche ; les admins voient tout
create policy brokers_select on public.brokers for select to anon, authenticated
  using (id = (select app_broker_id()) or (select app_is_admin()));
create policy brokers_update on public.brokers for update to anon, authenticated
  using (id = (select app_broker_id()) or (select app_is_admin()))
  with check (id = (select app_broker_id()) or (select app_is_admin()));
create policy brokers_insert on public.brokers for insert to anon, authenticated
  with check ((select app_is_admin()));
create policy brokers_delete on public.brokers for delete to anon, authenticated
  using ((select app_is_admin()));

-- answers / observations : les siennes, ou toutes pour un admin
create policy answers_own on public.answers for all to anon, authenticated
  using (broker_id = (select app_broker_id()) or (select app_is_admin()))
  with check (broker_id = (select app_broker_id()) or (select app_is_admin()));
create policy observations_own on public.observations for all to anon, authenticated
  using (broker_id = (select app_broker_id()) or (select app_is_admin()))
  with check (broker_id = (select app_broker_id()) or (select app_is_admin()));

-- groupements : lecture pour toute personne connectée, écriture admin
create policy groupements_read on public.groupements for select to anon, authenticated
  using ((select app_broker_id()) is not null);
create policy groupements_write on public.groupements for all to anon, authenticated
  using ((select app_is_admin())) with check ((select app_is_admin()));

-- ── 2. Champs réservés : seul un admin / super admin peut les changer ───────
create or replace function public.app_guard_broker_fields()
returns trigger language plpgsql as $$
begin
  if current_user in ('anon', 'authenticated') then
    if new.is_admin is distinct from old.is_admin and not app_is_super_admin() then
      raise exception 'Seul le super admin peut modifier les droits admin' using errcode = '42501';
    end if;
    if not app_is_admin() and (
         new.email            is distinct from old.email
      or new.deleted_at       is distinct from old.deleted_at
      or new.invite_token     is distinct from old.invite_token
      or new.invite_token_used is distinct from old.invite_token_used
      or new.sales_email      is distinct from old.sales_email
      or new.odoo_id          is distinct from old.odoo_id) then
      raise exception 'Modification réservée aux administrateurs' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists app_guard_broker_fields on public.brokers;
create trigger app_guard_broker_fields before update on public.brokers
  for each row execute function public.app_guard_broker_fields();

-- ── 3. Retirer l'ancien mot de passe de la table brokers ────────────────────
drop trigger if exists app_sync_legacy_pwd on public.brokers;
drop function if exists public.app_sync_legacy_pwd();

-- Sécurité : reprendre une dernière fois les hashes non encore migrés
insert into public.broker_secrets (broker_id, pwd_sha256)
select id, password_hash from public.brokers
 where password_hash is not null
on conflict (broker_id) do nothing;

alter table public.brokers drop column if exists password_hash;

-- ── 4. Codis : uniquement le jeton de session ───────────────────────────────
create or replace function public.get_comcom_data(p_email text, p_password_hash text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_payload jsonb; v_updated_at timestamptz;
begin
  if not exists (
    select 1 from app_sessions s join brokers b on b.id = s.broker_id
    where s.token = p_password_hash and s.expires_at > now()
      and lower(b.email) = lower(p_email) and b.deleted_at is null
      and app_broker_is_admin(b.id)
  ) then
    raise exception 'Acces refuse';
  end if;
  select payload, updated_at into v_payload, v_updated_at from comcom_data where id = 1;
  return v_payload || jsonb_build_object('updated_at', v_updated_at);
end $$;

-- Ancienne fonction plus utilisée (contenait un jeton GitHub en clair)
drop function if exists public.trigger_comcom_refresh(text, text);

notify pgrst, 'reload schema';
