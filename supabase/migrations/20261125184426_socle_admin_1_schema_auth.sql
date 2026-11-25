-- ===== Comptes =====
alter table public.acces drop constraint if exists acces_role_check;
update public.acces set role = 'utilisateur' where role = 'vendeur';
alter table public.acces add constraint acces_role_check check (role in ('admin','utilisateur'));
alter table public.acces
  add column doit_changer_pin boolean not null default false,
  add column echecs int not null default 0,
  add column bloque_jusqu timestamptz,
  add column derniere_connexion timestamptz,
  add column cree_le timestamptz not null default now();

-- ===== Droits par secteur =====
create table public.droits (
  acces_id bigint not null references public.acces(id) on delete cascade,
  secteur text not null,
  niveau text not null check (niveau in ('aucun','lecture','saisie','gestion')),
  primary key (acces_id, secteur)
);
insert into public.droits(acces_id, secteur, niveau) select id, 'boutique', 'saisie' from public.acces where role = 'utilisateur';

-- ===== Sessions =====
create table public.sessions (
  token uuid primary key default gen_random_uuid(),
  acces_id bigint not null references public.acces(id) on delete cascade,
  cree_le timestamptz not null default now(),
  expire_le timestamptz not null,
  derniere_activite timestamptz not null default now(),
  inactivite_max interval
);
create index on public.sessions(acces_id);

-- ===== Journal d'activité =====
create table public.journal (
  id bigint generated always as identity primary key,
  quand timestamptz not null default now(),
  acces_id bigint,
  nom text not null default '',
  action text not null,
  cible text not null default '',
  details jsonb not null default '{}'
);
create index on public.journal(quand desc);

-- ===== Ventes : annulation tracée =====
alter table public.ventes
  add column annulee boolean not null default false,
  add column annulee_le timestamptz,
  add column annulee_par text,
  add column motif_annulation text;

alter table public.droits enable row level security;
alter table public.sessions enable row level security;
alter table public.journal enable row level security;
revoke all on public.droits, public.sessions, public.journal from anon, authenticated;

-- ===== Fonctions internes =====
create or replace function public._stock(p_ref text)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select stock_initial from catalogue where ref = p_ref),0)
       + coalesce((select sum(quantite) from entrees where ref = p_ref),0)
       - coalesce((select sum(quantite) from ventes where ref = p_ref and not annulee),0)
       + coalesce((select sum(quantite) from ajustements where ref = p_ref),0)
$$;

create or replace function public._log(a public.acces, p_action text, p_cible text default '', p_details jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into journal(acces_id, nom, action, cible, details) values (a.id, coalesce(a.nom,''), p_action, coalesce(p_cible,''), coalesce(p_details,'{}'))
$$;

-- Résout un jeton de session "T:<uuid>" en compte actif
create or replace function public._acces(p_pin text)
returns public.acces language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; t uuid;
begin
  if coalesce(p_pin,'') not like 'T:%' then return null; end if;
  begin t := substr(p_pin, 3)::uuid; exception when others then return null; end;
  select ac.* into a from sessions s join acces ac on ac.id = s.acces_id
   where s.token = t and s.expire_le > now() and ac.actif
     and (s.inactivite_max is null or s.derniere_activite > now() - s.inactivite_max);
  if a.id is null then return null; end if;
  update sessions set derniere_activite = now() where token = t and derniere_activite < now() - interval '1 minute';
  return a;
end $$;

create or replace function public._niveau(a public.acces, p_secteur text)
returns text language sql stable security definer set search_path = public as $$
  select case when a.role = 'admin' then 'gestion'
              else coalesce((select niveau from droits where acces_id = a.id and secteur = p_secteur), 'aucun') end
$$;

-- p_min : 'lecture' (consulter), 'saisie' (saisir), 'gestion' (tout)
create or replace function public._peut(a public.acces, p_secteur text, p_min text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare n text;
begin
  if a.id is null or not a.actif or a.doit_changer_pin then return false; end if;
  n := _niveau(a, p_secteur);
  return case p_min when 'lecture' then n in ('lecture','gestion')
                    when 'saisie' then n in ('saisie','gestion')
                    when 'gestion' then n = 'gestion' else false end;
end $$;

create or replace function public._err(msg text)
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object('ok', false, 'erreur',
    case when msg like 'PIN incorrect%' or msg = 'session' then 'Session expirée : reconnecte-toi.'
         when msg = 'droits' then 'Tu n''as pas les droits pour cette action.'
         else msg end,
    'code', case when msg like 'PIN incorrect%' or msg = 'session' then 'session' when msg = 'droits' then 'droits' else null end)
$$;

-- ===== Connexion / déconnexion =====
drop function if exists public.api_connexion(text);
create or replace function public.api_connexion(p_identifiant text, p_pin text, p_rester boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; nb int; t uuid;
begin
  select count(*) into nb from tentatives where not ok and quand > now() - interval '15 minutes';
  if nb >= 200 then return _err('Trop de tentatives sur l''appli : réessaie dans quelques minutes.'); end if;
  delete from tentatives where quand < now() - interval '1 day';
  select * into a from acces where lower(identifiant) = lower(trim(coalesce(p_identifiant,'')));
  if a.id is null or not a.actif then
    insert into tentatives(ok) values (false);
    return _err('Identifiant ou code PIN incorrect.');
  end if;
  if a.bloque_jusqu is not null and a.bloque_jusqu > now() then
    return _err('Compte bloqué après plusieurs erreurs, réessaie après ' || to_char(a.bloque_jusqu at time zone 'Europe/Paris', 'HH24:MI') || ' (ou demande à l''administrateur).');
  end if;
  if a.pin_hash <> crypt(coalesce(p_pin,''), a.pin_hash) then
    insert into tentatives(ok) values (false);
    update acces set echecs = echecs + 1,
      bloque_jusqu = case when echecs + 1 >= 5 then now() + interval '15 minutes' else bloque_jusqu end
     where id = a.id returning * into a;
    perform _log(a, 'Échec de connexion', a.identifiant, jsonb_build_object('essais', a.echecs));
    if a.echecs >= 5 then
      update acces set echecs = 0 where id = a.id;
      return _err('5 codes faux : compte bloqué 15 minutes.');
    end if;
    return _err('Identifiant ou code PIN incorrect (' || (5 - a.echecs) || ' essai(s) restant(s)).');
  end if;
  update acces set echecs = 0, bloque_jusqu = null, derniere_connexion = now() where id = a.id;
  delete from sessions where expire_le < now() or (inactivite_max is not null and derniere_activite < now() - inactivite_max);
  insert into sessions(acces_id, expire_le, inactivite_max)
  values (a.id, now() + case when p_rester then interval '30 days' else interval '12 hours' end,
          case when p_rester then null else interval '2 hours' end)
  returning token into t;
  perform _log(a, 'Connexion', '', jsonb_build_object('rester_connecte', coalesce(p_rester,false)));
  return jsonb_build_object('ok', true, 'jeton', 'T:' || t, 'nom', a.nom, 'role', a.role, 'doit_changer_pin', a.doit_changer_pin);
end $$;

create or replace function public.api_deconnexion(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is not null then
    delete from sessions where token = substr(p_pin,3)::uuid;
    perform _log(a, 'Déconnexion');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_changer_pin(p_pin text, p_ancien text, p_nouveau text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if a.pin_hash <> crypt(coalesce(p_ancien,''), a.pin_hash) then return _err('Code actuel incorrect.'); end if;
  if coalesce(p_nouveau,'') !~ '^[0-9]{4}$' then return _err('Le nouveau code doit faire exactement 4 chiffres.'); end if;
  if p_nouveau in ('0000','1111','2222','3333','4444','5555','6666','7777','8888','9999','1234','4321','0123','1212','2580','1004','2000','2026','2027')
    then return _err('Code trop simple, choisis-en un autre.'); end if;
  if p_nouveau = p_ancien then return _err('Le nouveau code doit être différent de l''ancien.'); end if;
  update acces set pin_hash = crypt(p_nouveau, gen_salt('bf')), doit_changer_pin = false where id = a.id;
  delete from sessions where acces_id = a.id and token <> substr(p_pin,3)::uuid;
  perform _log(a, 'Changement de code PIN');
  return jsonb_build_object('ok', true);
end $$;
drop function if exists public.api_changer_pin(text, text);
;
