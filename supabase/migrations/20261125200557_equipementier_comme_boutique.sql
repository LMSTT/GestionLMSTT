delete from public.droits where secteur = 'equipementier';

create or replace function public._e(a public.acces, p_cle text)
returns boolean language sql stable security definer set search_path = public as $$
  select a.id is not null and a.actif and not a.doit_changer_pin
     and (a.role = 'admin' or exists (select 1 from droits where acces_id = a.id and secteur = 'equipementier:' || p_cle))
$$;
create or replace function public._equip(a public.acces)
returns boolean language sql stable security definer set search_path = public as $$
  select _e(a,'bord') or _e(a,'ca') or _e(a,'dot')
$$;
create or replace function public._droits(a public.acces)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'caisse', _a(a,'caisse'), 'stocks', _a(a,'stocks'), 'ventes', _a(a,'ventes'), 'ventes_annuler', _a(a,'ventes_annuler'),
    'entrees', _a(a,'entrees'), 'bilan', _a(a,'bilan'), 'catalogue', _a(a,'catalogue'),
    'eq_bord', _e(a,'bord'), 'eq_ca', _e(a,'ca'), 'eq_dot', _e(a,'dot'), 'equipementier', _equip(a),
    'administration', a.role = 'admin' and a.actif and not a.doit_changer_pin)
$$;

do $$
declare f text;
begin
  for f in select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('api_equip_saison','api_equip_ca','api_equip_dotation') loop
    f := replace(f, 'if not _equip(a) then', case
           when f like '%FUNCTION public.api_equip_saison%' then 'if not _e(a,''bord'') then'
           when f like '%FUNCTION public.api_equip_ca%' then 'if not _e(a,''ca'') then'
           else 'if not _e(a,''dot'') then' end);
    execute f;
  end loop;
end $$;

create or replace function public.api_equip_suppr(p_pin text, p_type text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; old jsonb;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if p_type = 'ca' then
    if not _e(a,'ca') then return _err('droits'); end if;
    delete from equip_ca x where x.id = p_id returning to_jsonb(x) into old;
  elsif p_type = 'dotation' then
    if not _e(a,'dot') then return _err('droits'); end if;
    delete from equip_dotations x where x.id = p_id returning to_jsonb(x) into old;
  else return _err('Type inconnu.'); end if;
  if old is null then return _err('Ligne introuvable.'); end if;
  perform _log(a, 'Équipementier : suppression', p_type, old);
  return jsonb_build_object('ok', true);
end $$;

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
        'acces', coalesce((select jsonb_agg(case when secteur like 'equipementier:%' then 'eq_' || substr(secteur, 15) else substr(secteur, 10) end order by secteur)
                           from droits d where d.acces_id = u.id and (secteur like 'boutique:%' or secteur like 'equipementier:%')), '[]'))
      order by u.role, u.nom) from acces u), '[]'),
    'journal', coalesce((select jsonb_agg(to_jsonb(j) order by j.quand desc) from (select * from journal order by quand desc limit 500) j), '[]'),
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres where cle <> 'session'), '{}'));
end $$;

create or replace function public.api_admin_utilisateur(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; u public.acces; ident text; k text; nouveau boolean; ancien text;
        cles text[] := array['caisse','stocks','ventes','ventes_annuler','entrees','bilan','catalogue','eq_bord','eq_ca','eq_dot'];
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  if coalesce(trim(p->>'nom'),'') = '' then return _err('Indique le nom.'); end if;
  if coalesce(p->>'role','utilisateur') not in ('admin','utilisateur') then return _err('Profil inconnu.'); end if;
  ident := lower(trim(coalesce(p->>'identifiant','')));
  nouveau := nullif(p->>'id','') is null;
  if ident !~ '^[a-z0-9._-]{2,30}$' then return _err('Identifiant : 2 à 30 caractères, lettres sans accent, chiffres, point ou tiret.'); end if;
  if exists (select 1 from acces where lower(identifiant) = ident and (nouveau or id <> (p->>'id')::bigint)) then return _err('Cet identifiant est déjà utilisé.'); end if;
  if nouveau then
    if coalesce(p->>'pin','') !~ '^[0-9]{4}$' then return _err('Code provisoire : 4 chiffres.'); end if;
    insert into acces(nom, role, identifiant, pin_hash, doit_changer_pin)
    values (trim(p->>'nom'), coalesce(p->>'role','utilisateur'), ident, crypt(p->>'pin', gen_salt('bf')), true) returning * into u;
  else
    select * into u from acces where id = (p->>'id')::bigint;
    if u.id is null then return _err('Utilisateur introuvable.'); end if;
    if u.id = a.id and (coalesce(p->>'role','admin') <> 'admin' or coalesce((p->>'actif')::boolean, true) = false) then
      return _err('Tu ne peux pas retirer ton propre accès administrateur.'); end if;
    ancien := u.identifiant;
    update acces set nom = trim(p->>'nom'), identifiant = ident, role = coalesce(p->>'role', role), actif = coalesce((p->>'actif')::boolean, actif),
      bloque_jusqu = case when coalesce((p->>'debloquer')::boolean,false) then null else bloque_jusqu end,
      echecs = case when coalesce((p->>'debloquer')::boolean,false) then 0 else echecs end
     where id = u.id returning * into u;
    if not u.actif then delete from sessions where acces_id = u.id; end if;
  end if;
  if jsonb_typeof(p->'acces') = 'array' then
    delete from droits where acces_id = u.id and (secteur like 'boutique:%' or secteur like 'equipementier%');
    for k in select jsonb_array_elements_text(p->'acces') loop
      if not k = any(cles) then return _err('Accès inconnu : ' || k); end if;
      insert into droits(acces_id, secteur, niveau)
      values (u.id, case when k like 'eq\_%' then 'equipementier:' || substr(k, 4) else 'boutique:' || k end, 'oui') on conflict do nothing;
    end loop;
  end if;
  perform _log(a, case when nouveau then 'Création d''utilisateur' else 'Modification d''utilisateur' end, u.identifiant,
               jsonb_build_object('nom', u.nom, 'role', u.role, 'actif', u.actif, 'acces', p->'acces')
               || case when ancien is not null and ancien <> u.identifiant then jsonb_build_object('ancien_identifiant', ancien) else '{}' end);
  return jsonb_build_object('ok', true, 'id', u.id);
end $$;

revoke execute on function public._e(public.acces, text) from public, anon, authenticated;
revoke execute on function public.api_admin_utilisateur(text, jsonb), public.api_admin_donnees(text), public.api_equip_suppr(text,text,bigint) from public;
grant execute on function public.api_admin_utilisateur(text, jsonb), public.api_admin_donnees(text), public.api_equip_suppr(text,text,bigint) to anon, authenticated;
;
