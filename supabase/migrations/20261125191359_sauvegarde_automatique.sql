create table public.secrets (cle text primary key, hash text not null, maj_le timestamptz not null default now());
alter table public.secrets enable row level security;
revoke all on public.secrets from anon, authenticated;

create or replace function public._export()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('exporte_le', now(),
    'catalogue', coalesce((select jsonb_agg(c) from catalogue c), '[]'),
    'ventes', coalesce((select jsonb_agg(v order by v.num) from ventes v), '[]'),
    'entrees', coalesce((select jsonb_agg(e order by e.id) from entrees e), '[]'),
    'ajustements', coalesce((select jsonb_agg(j order by j.id) from ajustements j), '[]'),
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres), '{}'),
    'utilisateurs', coalesce((select jsonb_agg(jsonb_build_object('nom', nom, 'identifiant', identifiant, 'role', role, 'actif', actif)) from acces), '[]'),
    'droits', coalesce((select jsonb_agg(jsonb_build_object('identifiant', ac.identifiant, 'acces', d.secteur)) from droits d join acces ac on ac.id = d.acces_id), '[]'),
    'journal', coalesce((select jsonb_agg(j order by j.id) from journal j), '[]'))
$$;

create or replace function public.api_admin_export(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  perform _log(a, 'Export de sauvegarde');
  return jsonb_build_object('ok', true) || _export();
end $$;

create or replace function public.api_admin_cle_sauvegarde(p_pin text, p_cle text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  if length(coalesce(p_cle,'')) < 16 or p_cle !~ '^[A-Za-z0-9_-]+$' then return _err('Clé : au moins 16 caractères (lettres, chiffres, - ou _).'); end if;
  insert into secrets(cle, hash) values ('sauvegarde', crypt(p_cle, gen_salt('bf'))) on conflict (cle) do update set hash = excluded.hash, maj_le = now();
  perform _log(a, 'Clé de sauvegarde automatique définie');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_sauvegarde_auto(p_cle text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare h text; nb int;
begin
  select count(*) into nb from tentatives where not ok and quand > now() - interval '15 minutes';
  if nb >= 200 then return _err('Trop de tentatives.'); end if;
  select hash into h from secrets where cle = 'sauvegarde';
  if h is null or h <> crypt(coalesce(p_cle,''), h) then insert into tentatives(ok) values (false); return _err('Clé de sauvegarde invalide.'); end if;
  insert into journal(nom, action) values ('GitHub', 'Sauvegarde automatique');
  return jsonb_build_object('ok', true) || _export();
end $$;

create or replace function public.api_admin_etat_sauvegarde(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  return jsonb_build_object('ok', true, 'cle_definie_le', (select maj_le from secrets where cle = 'sauvegarde'),
    'derniere_auto', (select max(quand) from journal where action = 'Sauvegarde automatique'));
end $$;

revoke execute on function public._export() from public, anon, authenticated;
revoke execute on function public.api_admin_cle_sauvegarde(text, text), public.api_sauvegarde_auto(text), public.api_admin_etat_sauvegarde(text) from public;
grant execute on function public.api_admin_cle_sauvegarde(text, text), public.api_sauvegarde_auto(text), public.api_admin_etat_sauvegarde(text) to anon, authenticated;
;
