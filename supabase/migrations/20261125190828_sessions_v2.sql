alter table public.sessions
  add column id bigint generated always as identity,
  add column appareil text not null default '',
  add column rester boolean not null default false;
create unique index sessions_id_key on public.sessions(id);

insert into public.parametres(cle, valeurs) values ('session', '{"duree_h":12,"inactivite_min":120,"rester_autorise":true,"rester_jours":30,"verrou_min":0}')
on conflict (cle) do nothing;

create or replace function public._reglages()
returns jsonb language sql stable security definer set search_path = public as $$
  select '{"duree_h":12,"inactivite_min":120,"rester_autorise":true,"rester_jours":30,"verrou_min":0}'::jsonb
         || coalesce((select valeurs from parametres where cle = 'session'), '{}')
$$;

drop function if exists public.api_connexion(text, text, boolean);
create or replace function public.api_connexion(p_identifiant text, p_pin text, p_rester boolean default false, p_appareil text default '')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; nb int; t uuid; g jsonb := _reglages(); r boolean;
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
    perform _log(a, 'Échec de connexion', a.identifiant, jsonb_build_object('essais', a.echecs, 'appareil', left(coalesce(p_appareil,''),80)));
    if a.echecs >= 5 then update acces set echecs = 0 where id = a.id; return _err('5 codes faux : compte bloqué 15 minutes.'); end if;
    return _err('Identifiant ou code PIN incorrect (' || (5 - a.echecs) || ' essai(s) restant(s)).');
  end if;
  r := coalesce(p_rester,false) and coalesce((g->>'rester_autorise')::boolean, true);
  update acces set echecs = 0, bloque_jusqu = null, derniere_connexion = now() where id = a.id;
  delete from sessions where expire_le < now() or (inactivite_max is not null and derniere_activite < now() - inactivite_max);
  insert into sessions(acces_id, expire_le, inactivite_max, appareil, rester)
  values (a.id,
          now() + case when r then make_interval(days => greatest(1, (g->>'rester_jours')::int)) else make_interval(hours => greatest(1, (g->>'duree_h')::int)) end,
          case when r then null else make_interval(mins => greatest(5, (g->>'inactivite_min')::int)) end,
          left(coalesce(p_appareil,''), 80), r)
  returning token into t;
  perform _log(a, 'Connexion', '', jsonb_build_object('rester_connecte', r, 'appareil', left(coalesce(p_appareil,''),80)));
  return jsonb_build_object('ok', true, 'jeton', 'T:' || t, 'nom', a.nom, 'role', a.role, 'doit_changer_pin', a.doit_changer_pin,
                            'rester', r, 'verrou_min', (g->>'verrou_min')::int);
end $$;

-- Vérifie le code pour déverrouiller l'écran (même règle de blocage)
create or replace function public.api_deverrouiller(p_pin text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if a.pin_hash = crypt(coalesce(p_code,''), a.pin_hash) then
    update acces set echecs = 0 where id = a.id;
    return jsonb_build_object('ok', true);
  end if;
  update acces set echecs = echecs + 1 where id = a.id returning * into a;
  perform _log(a, 'Échec de déverrouillage', '', jsonb_build_object('essais', a.echecs));
  if a.echecs >= 5 then
    update acces set echecs = 0, bloque_jusqu = now() + interval '15 minutes' where id = a.id;
    delete from sessions where token = substr(p_pin,3)::uuid;
    return _err('session');
  end if;
  return _err('Code incorrect (' || (5 - a.echecs) || ' essai(s) restant(s)).');
end $$;

create or replace function public._liste_sessions(p_filtre bigint, p_courant uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'nom', u.nom, 'identifiant', u.identifiant, 'appareil', s.appareil, 'rester', s.rester,
           'cree_le', s.cree_le, 'derniere_activite', s.derniere_activite, 'expire_le', s.expire_le, 'courante', s.token = p_courant)
         order by s.derniere_activite desc), '[]')
  from sessions s join acces u on u.id = s.acces_id
  where s.expire_le > now() and (s.inactivite_max is null or s.derniere_activite > now() - s.inactivite_max)
    and (p_filtre is null or s.acces_id = p_filtre)
$$;

create or replace function public.api_mes_sessions(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  return jsonb_build_object('ok', true, 'sessions', _liste_sessions(a.id, substr(p_pin,3)::uuid));
end $$;

create or replace function public.api_fermer_session(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; s record;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  select ss.*, u.identifiant, u.nom into s from sessions ss join acces u on u.id = ss.acces_id where ss.id = p_id;
  if s.id is null then return _err('Session introuvable.'); end if;
  if s.acces_id <> a.id and not _est_admin(a) then return _err('droits'); end if;
  delete from sessions where id = p_id;
  perform _log(a, 'Fermeture de session', s.identifiant, jsonb_build_object('appareil', s.appareil));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_admin_reglages(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; v jsonb; avant jsonb := _reglages();
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  begin
    v := jsonb_build_object(
      'duree_h', least(72, greatest(1, (p->>'duree_h')::int)),
      'inactivite_min', least(1440, greatest(5, (p->>'inactivite_min')::int)),
      'rester_autorise', coalesce((p->>'rester_autorise')::boolean, true),
      'rester_jours', least(90, greatest(1, (p->>'rester_jours')::int)),
      'verrou_min', least(240, greatest(0, (p->>'verrou_min')::int)));
  exception when others then return _err('Valeurs invalides.'); end;
  insert into parametres(cle, valeurs) values ('session', v) on conflict (cle) do update set valeurs = excluded.valeurs;
  perform _log(a, 'Modification des réglages de session', '', jsonb_build_object('avant', avant, 'apres', v));
  return jsonb_build_object('ok', true);
end $$;

-- verrou dans les données de l'utilisateur
create or replace function public.api_donnees(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; d jsonb; anyb boolean; pa boolean; vv boolean; mv boolean;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  d := _droits(a);
  anyb := (d->>'caisse')::boolean or (d->>'stocks')::boolean or (d->>'ventes')::boolean or (d->>'entrees')::boolean or (d->>'bilan')::boolean or (d->>'catalogue')::boolean;
  pa := (d->>'stocks')::boolean or (d->>'entrees')::boolean or (d->>'bilan')::boolean or (d->>'catalogue')::boolean;
  vv := (d->>'ventes')::boolean or (d->>'bilan')::boolean;
  mv := (d->>'entrees')::boolean or (d->>'bilan')::boolean;
  return jsonb_build_object(
    'ok', true, 'nom', a.nom, 'role', a.role, 'identifiant', a.identifiant, 'doit_changer_pin', a.doit_changer_pin, 'droits', d,
    'verrou_min', (_reglages()->>'verrou_min')::int,
    'catalogue', case when not anyb then '[]'::jsonb else coalesce((select jsonb_agg(
        case when pa then to_jsonb(c) else to_jsonb(c) - 'prix_achat' - 'description' end
        || jsonb_build_object('stock', _stock(c.ref)) order by c.categorie, c.designation, c.declinaison) from catalogue c), '[]') end,
    'ventes', case when vv then coalesce((select jsonb_agg(v order by v.date desc, v.num desc) from ventes v), '[]') else '[]' end,
    'entrees', case when mv then coalesce((select jsonb_agg(e order by e.date desc, e.id desc) from entrees e), '[]') else '[]' end,
    'ajustements', case when mv then coalesce((select jsonb_agg(j order by j.date desc, j.id desc) from ajustements j), '[]') else '[]' end,
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres where cle = 'modes' or ((d->>'entrees')::boolean or (d->>'catalogue')::boolean) and cle <> 'session'), '{}')
  );
end $$;

-- admin : sessions + réglages
create or replace function public.api_admin_donnees(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  return jsonb_build_object('ok', true, 'moi', a.id, 'reglages', _reglages(),
    'sessions', _liste_sessions(null, substr(p_pin,3)::uuid),
    'utilisateurs', coalesce((select jsonb_agg(jsonb_build_object(
        'id', u.id, 'nom', u.nom, 'identifiant', u.identifiant, 'role', u.role, 'actif', u.actif,
        'doit_changer_pin', u.doit_changer_pin, 'bloque_jusqu', case when u.bloque_jusqu > now() then u.bloque_jusqu end,
        'derniere_connexion', u.derniere_connexion, 'cree_le', u.cree_le,
        'sessions', (select count(*) from sessions s where s.acces_id = u.id and s.expire_le > now() and (s.inactivite_max is null or s.derniere_activite > now() - s.inactivite_max)),
        'acces', coalesce((select jsonb_agg(substr(secteur, 10) order by secteur) from droits d where d.acces_id = u.id and secteur like 'boutique:%'), '[]'))
      order by u.role, u.nom) from acces u), '[]'),
    'journal', coalesce((select jsonb_agg(to_jsonb(j) order by j.quand desc) from (select * from journal order by quand desc limit 500) j), '[]'),
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres where cle <> 'session'), '{}'));
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.api_ping(), public.api_identifiants(),
  public.api_connexion(text, text, boolean, text), public.api_deconnexion(text), public.api_changer_pin(text, text, text), public.api_deverrouiller(text, text),
  public.api_donnees(text), public.api_compte(text), public.api_mes_sessions(text), public.api_fermer_session(text, bigint),
  public.api_vente(text, jsonb), public.api_annuler_vente(text, text, text), public.api_entree(text, jsonb),
  public.api_ajustement(text, jsonb), public.api_supprimer_mouvement(text, text, bigint), public.api_article(text, jsonb),
  public.api_admin_donnees(text), public.api_admin_utilisateur(text, jsonb), public.api_admin_reset_pin(text, bigint, text),
  public.api_admin_fermer_sessions(text, bigint), public.api_admin_parametre(text, text, jsonb), public.api_admin_export(text), public.api_admin_reglages(text, jsonb)
to anon, authenticated;
;
