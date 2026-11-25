-- =============================================================================
-- SÉCURITÉ — PHASE A : préparation (NON BLOQUANTE)
-- -----------------------------------------------------------------------------
-- À exécuter AVANT de mettre en ligne le nouveau front (PR "sécurité").
-- Ne ferme encore rien : les apps actuelles continuent de fonctionner.
--
-- Crée :
--   • broker_secrets  : mots de passe (bcrypt), invisibles via l'API
--   • app_sessions    : jetons de session (30 jours), invisibles via l'API
--   • fonctions de login / session / mot de passe appelées par le front
--   • fonctions d'aide utilisées par les règles RLS de la phase C
-- =============================================================================

-- ── 1. Tables privées ───────────────────────────────────────────────────────
create table if not exists public.broker_secrets (
  broker_id   uuid primary key references public.brokers(id) on delete cascade,
  pwd_bcrypt  text,          -- format sûr (bcrypt, salé)
  pwd_sha256  text,          -- ancien format, effacé à la 1re connexion réussie
  updated_at  timestamptz not null default now()
);
alter table public.broker_secrets enable row level security;   -- aucune règle = invisible
revoke all on public.broker_secrets from anon, authenticated;

create table if not exists public.app_sessions (
  token       text primary key,
  broker_id   uuid not null references public.brokers(id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '30 days'
);
create index if not exists app_sessions_broker_idx on public.app_sessions(broker_id);
alter table public.app_sessions enable row level security;     -- aucune règle = invisible
revoke all on public.app_sessions from anon, authenticated;

-- Le nouveau front n'écrit plus de hash dans brokers
alter table public.brokers alter column password_hash drop not null;

-- ── 2. Reprise des mots de passe existants ──────────────────────────────────
insert into public.broker_secrets (broker_id, pwd_sha256)
select id, password_hash from public.brokers where password_hash is not null
on conflict (broker_id) do nothing;

-- Transition : si l'ANCIEN front change un mot de passe, on le recopie
create or replace function public.app_sync_legacy_pwd()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.password_hash is not null
     and (tg_op = 'INSERT' or new.password_hash is distinct from old.password_hash) then
    insert into broker_secrets (broker_id, pwd_sha256, pwd_bcrypt, updated_at)
    values (new.id, new.password_hash, null, now())
    on conflict (broker_id) do update
      set pwd_sha256 = excluded.pwd_sha256, pwd_bcrypt = null, updated_at = now();
  end if;
  return new;
end $$;

drop trigger if exists app_sync_legacy_pwd on public.brokers;
create trigger app_sync_legacy_pwd
  after insert or update of password_hash on public.brokers
  for each row execute function public.app_sync_legacy_pwd();

-- ── 3. Fonctions d'aide (utilisées par les règles RLS) ──────────────────────
-- Jeton envoyé par le front dans l'en-tête HTTP « x-procyo-token »
create or replace function public.app_token()
returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-procyo-token', '')
$$;

-- Courtier connecté (null si pas de session valide)
create or replace function public.app_broker_id()
returns uuid language sql stable security definer set search_path = public as $$
  select s.broker_id
  from app_sessions s join brokers b on b.id = s.broker_id
  where s.token = app_token() and s.expires_at > now() and b.deleted_at is null
  limit 1
$$;

-- Liste historique des admins (identique à ADMIN_EMAILS dans le front)
create or replace function public.app_admin_emails()
returns text[] language sql immutable as $$
  select array['cedric.jaumot@procyo.be','gianni.luyckx@procyo.be','antoine.moriau@procyo.be',
               'maxime.dejean@procyo.be','eric.vandoren@procyo.be','admin@procyo.be',
               'luc.renard@procyo.be','procyo@procyo.be']
$$;

create or replace function public.app_broker_is_admin(p_broker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select b.is_admin is true or lower(b.email) = any(app_admin_emails())
                   from brokers b where b.id = p_broker), false)
$$;

create or replace function public.app_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select app_broker_is_admin(app_broker_id())
$$;

create or replace function public.app_is_super_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from brokers b
                 where b.id = app_broker_id() and lower(b.email) = 'cedric.jaumot@procyo.be')
$$;

-- Fiche courtier sans les champs sensibles
create or replace function public.app_public_broker(b public.brokers)
returns jsonb language sql stable as $$
  select to_jsonb(b) - 'password_hash' - 'invite_token'
$$;

-- ── 4. Fonctions internes (non appelables depuis le front) ──────────────────
create or replace function public.app_check_password(p_broker uuid, p_password text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare s broker_secrets;
begin
  select * into s from broker_secrets where broker_id = p_broker;
  if not found or p_password is null then return false; end if;
  if s.pwd_bcrypt is not null then
    return s.pwd_bcrypt = crypt(p_password, s.pwd_bcrypt);
  end if;
  if s.pwd_sha256 is not null and s.pwd_sha256 = encode(digest(p_password, 'sha256'), 'hex') then
    -- Mise à niveau transparente vers bcrypt
    update broker_secrets
       set pwd_bcrypt = crypt(p_password, gen_salt('bf', 10)), pwd_sha256 = null, updated_at = now()
     where broker_id = p_broker;
    return true;
  end if;
  return false;
end $$;

create or replace function public.app_set_password(p_broker uuid, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_password is null or length(p_password) < 8 then
    raise exception 'Mot de passe : 8 caractères minimum' using errcode = '22023';
  end if;
  insert into broker_secrets (broker_id, pwd_bcrypt, pwd_sha256, updated_at)
  values (p_broker, crypt(p_password, gen_salt('bf', 10)), null, now())
  on conflict (broker_id) do update
    set pwd_bcrypt = excluded.pwd_bcrypt, pwd_sha256 = null, updated_at = now();
end $$;

create or replace function public.app_new_session(p_broker uuid)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_token text := encode(gen_random_bytes(32), 'hex');
begin
  delete from app_sessions where expires_at < now();
  insert into app_sessions (token, broker_id) values (v_token, p_broker);
  return v_token;
end $$;

-- ── 5. Fonctions appelées par le front (/rest/v1/rpc/...) ───────────────────
-- Connexion : renvoie { token, broker }
create or replace function public.app_login(p_email text, p_password text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b brokers;
begin
  select * into b from brokers
   where lower(email) = lower(trim(p_email)) and deleted_at is null
   order by created_at limit 1;
  if not found or not app_check_password(b.id, p_password) then
    perform pg_sleep(0.4);   -- freine les essais en rafale
    raise exception 'Identifiants incorrects' using errcode = '28P01';
  end if;
  return jsonb_build_object('token', app_new_session(b.id), 'broker', app_public_broker(b));
end $$;

-- Session courante : renvoie la fiche (ou null) et prolonge la session
create or replace function public.app_me()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid := app_broker_id(); b brokers;
begin
  if v_id is null then return null; end if;
  update app_sessions set expires_at = now() + interval '30 days'
   where token = app_token() and expires_at < now() + interval '29 days';
  select * into b from brokers where id = v_id;
  return app_public_broker(b);
end $$;

create or replace function public.app_logout()
returns void language sql security definer set search_path = public as $$
  delete from app_sessions where token = app_token()
$$;

-- Inscription libre d'un courtier (écran « Créer un compte » du Launchpad)
create or replace function public.app_register(p_email text, p_password text, p_company text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_email text := lower(trim(p_email)); b brokers;
begin
  if v_email !~ '^\S+@\S+\.\S+$' then
    raise exception 'Adresse email invalide' using errcode = '22023';
  end if;
  if exists (select 1 from brokers where lower(email) = v_email) then
    raise exception 'Un compte existe déjà pour cet email' using errcode = '23505';
  end if;
  if p_password is null or length(p_password) < 8 then
    raise exception 'Mot de passe : 8 caractères minimum' using errcode = '22023';
  end if;
  insert into brokers (email, company_name) values (v_email, nullif(trim(p_company), ''))
  returning * into b;
  perform app_set_password(b.id, p_password);
  return jsonb_build_object('token', app_new_session(b.id), 'broker', app_public_broker(b));
end $$;

-- Lien d'invitation : infos affichées avant activation
create or replace function public.app_invite_info(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'email', email, 'company_name', company_name)
  from brokers
  where invite_token = p_token and invite_token_used is not true
    and deleted_at is null and coalesce(p_token, '') <> ''
  limit 1
$$;

-- Activation via le lien d'invitation : choix du mot de passe + connexion
create or replace function public.app_activate(p_token text, p_password text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b brokers;
begin
  select * into b from brokers
   where invite_token = p_token and invite_token_used is not true
     and deleted_at is null and coalesce(p_token, '') <> ''
   limit 1;
  if not found then
    raise exception 'Lien invalide ou déjà utilisé' using errcode = '22023';
  end if;
  perform app_set_password(b.id, p_password);
  update brokers set invite_token_used = true where id = b.id returning * into b;
  return jsonb_build_object('token', app_new_session(b.id), 'broker', app_public_broker(b));
end $$;

-- Changement de son propre mot de passe
create or replace function public.app_change_password(p_current text, p_new text)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid := app_broker_id();
begin
  if v_id is null then raise exception 'Session expirée' using errcode = '28000'; end if;
  if not app_check_password(v_id, p_current) then
    raise exception 'Mot de passe actuel incorrect' using errcode = '28P01';
  end if;
  perform app_set_password(v_id, p_new);
end $$;

-- Admin : mot de passe temporaire pour un courtier
create or replace function public.app_admin_set_password(p_broker uuid, p_password text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not app_is_admin() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  perform app_set_password(p_broker, p_password);
  delete from app_sessions where broker_id = p_broker;   -- déconnecte l'ancien mot de passe
end $$;

-- Super admin : créer / promouvoir un accès admin
create or replace function public.app_admin_grant_admin(p_email text, p_password text)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text := lower(trim(p_email)); v_id uuid;
begin
  if not app_is_super_admin() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  select id into v_id from brokers where lower(email) = v_email order by created_at limit 1;
  if v_id is null then
    insert into brokers (email, is_admin) values (v_email, true) returning id into v_id;
  else
    update brokers set is_admin = true where id = v_id;
  end if;
  perform app_set_password(v_id, p_password);
end $$;

-- ── 6. Codis : accepte désormais le JETON de session ────────────────────────
-- (même nom de paramètre pour ne pas devoir redéployer l'Edge Function
--  refresh-comcom ; p_password_hash contient le jeton).
-- Transition : l'ancien hash reste accepté jusqu'à la phase C.
create or replace function public.get_comcom_data(p_email text, p_password_hash text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_valid boolean; v_payload jsonb; v_updated_at timestamptz;
begin
  select exists (
    select 1 from app_sessions s join brokers b on b.id = s.broker_id
    where s.token = p_password_hash and s.expires_at > now()
      and lower(b.email) = lower(p_email) and b.deleted_at is null
      and app_broker_is_admin(b.id)
  ) or exists (   -- ANCIEN MODE, supprimé en phase C
    select 1 from brokers
    where email = p_email and password_hash = p_password_hash and is_admin = true
  ) into v_valid;
  if not v_valid then raise exception 'Acces refuse'; end if;
  select payload, updated_at into v_payload, v_updated_at from comcom_data where id = 1;
  return v_payload || jsonb_build_object('updated_at', v_updated_at);
end $$;

-- ── 7. Droits d'exécution ───────────────────────────────────────────────────
revoke execute on function public.app_check_password(uuid, text)   from public, anon, authenticated;
revoke execute on function public.app_set_password(uuid, text)     from public, anon, authenticated;
revoke execute on function public.app_new_session(uuid)            from public, anon, authenticated;
revoke execute on function public.app_sync_legacy_pwd()            from public, anon, authenticated;
revoke execute on function public.app_broker_is_admin(uuid)        from public, anon, authenticated;

grant execute on function public.app_token(), public.app_broker_id(), public.app_is_admin(),
  public.app_is_super_admin(), public.app_admin_emails(),
  public.app_login(text, text), public.app_me(), public.app_logout(),
  public.app_register(text, text, text), public.app_invite_info(text),
  public.app_activate(text, text), public.app_change_password(text, text),
  public.app_admin_set_password(uuid, text), public.app_admin_grant_admin(text, text),
  public.get_comcom_data(text, text)
  to anon, authenticated;

-- PostgREST : recharger le schéma pour exposer les nouvelles fonctions
notify pgrst, 'reload schema';
