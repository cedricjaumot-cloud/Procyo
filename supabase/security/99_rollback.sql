-- =============================================================================
-- SÉCURITÉ — RETOUR ARRIÈRE de la phase C (en cas de problème bloquant)
-- -----------------------------------------------------------------------------
-- Rouvre les tables comme avant. Le nouveau front continue de fonctionner
-- (il passe par app_login). L'ancien front ne fonctionnera à nouveau que pour
-- les comptes dont le mot de passe n'a pas encore été migré en bcrypt.
-- =============================================================================

drop trigger if exists app_guard_broker_fields on public.brokers;

drop policy if exists brokers_select     on public.brokers;
drop policy if exists brokers_update     on public.brokers;
drop policy if exists brokers_insert     on public.brokers;
drop policy if exists brokers_delete     on public.brokers;
drop policy if exists answers_own        on public.answers;
drop policy if exists observations_own   on public.observations;
drop policy if exists groupements_read   on public.groupements;
drop policy if exists groupements_write  on public.groupements;

create policy brokers_open    on public.brokers      for all to public using (true);
create policy answers_open    on public.answers      for all to public using (true);
create policy obs_open        on public.observations for all to public using (true);
create policy groupements_all on public.groupements  for all to anon, authenticated using (true) with check (true);

alter table public.brokers add column if not exists password_hash text;
-- Désactive temporairement les webhooks de brokers (sinon 3 appels HTTP par ligne)
alter table public.brokers disable trigger user;
update public.brokers b set password_hash = s.pwd_sha256
  from public.broker_secrets s
 where s.broker_id = b.id and s.pwd_sha256 is not null and b.password_hash is null;
alter table public.brokers enable trigger user;

notify pgrst, 'reload schema';
