-- Droits par sous-menu : secteur = 'boutique:<onglet>', niveau = 'oui'
alter table public.droits drop constraint if exists droits_niveau_check;
insert into public.droits(acces_id, secteur, niveau)
select d.acces_id, 'boutique:' || k, 'oui' from public.droits d
cross join lateral unnest(case d.niveau when 'saisie' then array['caisse']
                                         when 'lecture' then array['stocks','ventes','bilan']
                                         when 'gestion' then array['caisse','stocks','ventes','ventes_annuler','entrees','bilan','catalogue']
                                         else array[]::text[] end) k
where d.secteur = 'boutique';
delete from public.droits where secteur = 'boutique';
alter table public.droits add constraint droits_niveau_check check (niveau = 'oui');

create or replace function public._a(a public.acces, p_cle text)
returns boolean language sql stable security definer set search_path = public as $$
  select a.id is not null and a.actif and not a.doit_changer_pin
     and (a.role = 'admin' or exists (select 1 from droits where acces_id = a.id and secteur = 'boutique:' || p_cle))
$$;

create or replace function public._droits(a public.acces)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'caisse', _a(a,'caisse'), 'stocks', _a(a,'stocks'), 'ventes', _a(a,'ventes'), 'ventes_annuler', _a(a,'ventes_annuler'),
    'entrees', _a(a,'entrees'), 'bilan', _a(a,'bilan'), 'catalogue', _a(a,'catalogue'),
    'administration', a.role = 'admin' and a.actif and not a.doit_changer_pin)
$$;

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
    'catalogue', case when not anyb then '[]'::jsonb else coalesce((select jsonb_agg(
        case when pa then to_jsonb(c) else to_jsonb(c) - 'prix_achat' - 'description' end
        || jsonb_build_object('stock', _stock(c.ref)) order by c.categorie, c.designation, c.declinaison) from catalogue c), '[]') end,
    'ventes', case when vv then coalesce((select jsonb_agg(v order by v.date desc, v.num desc) from ventes v), '[]') else '[]' end,
    'entrees', case when mv then coalesce((select jsonb_agg(e order by e.date desc, e.id desc) from entrees e), '[]') else '[]' end,
    'ajustements', case when mv then coalesce((select jsonb_agg(j order by j.date desc, j.id desc) from ajustements j), '[]') else '[]' end,
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres where cle = 'modes' or (d->>'entrees')::boolean or (d->>'catalogue')::boolean), '{}')
  );
end $$;

-- Remplace les contrôles de droits dans les fonctions métier
create or replace function public._peut(a public.acces, p_secteur text, p_min text)
returns boolean language sql stable security definer set search_path = public as $$
  select case p_min when 'saisie' then _a(a,'caisse') else false end
$$;

do $$
declare f text;
begin
  -- api_vente : caisse (inchangé via _peut 'saisie'). Les autres : remplacer le contrôle 'gestion'.
  for f in select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('api_annuler_vente','api_entree','api_ajustement','api_supprimer_mouvement','api_article') loop
    f := replace(f, 'not _peut(a, ''boutique'', ''gestion'')',
      case when f like '%FUNCTION public.api_annuler_vente%' then 'not _a(a, ''ventes_annuler'')'
           when f like '%FUNCTION public.api_article%' then 'not _a(a, ''catalogue'')'
           else 'not _a(a, ''entrees'')' end);
    execute f;
  end loop;
end $$;

create or replace function public.api_compte(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; deb date; today date := (now() at time zone 'Europe/Paris')::date;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  deb := make_date(extract(year from today)::int - case when extract(month from today) >= 8 then 0 else 1 end, 8, 1);
  return jsonb_build_object('ok', true, 'nom', a.nom, 'identifiant', a.identifiant, 'role', a.role, 'doit_changer_pin', a.doit_changer_pin,
    'droits', _droits(a), 'derniere_connexion', a.derniere_connexion,
    'saison', extract(year from deb)::int || '-' || (extract(year from deb)::int + 1),
    'nb_ventes', (select count(*) from ventes where vendeur = a.nom and date >= deb and not annulee),
    'montant', (select coalesce(sum(montant),0) from ventes where vendeur = a.nom and date >= deb and not annulee),
    'nb_jour', (select count(*) from ventes where vendeur = a.nom and date = today and not annulee),
    'montant_jour', (select coalesce(sum(montant),0) from ventes where vendeur = a.nom and date = today and not annulee),
    'derniere', (select max(date::text || ' ' || coalesce(to_char(heure,'HH24:MI'),'')) from ventes where vendeur = a.nom and not annulee),
    'ventes', coalesce((select jsonb_agg(jsonb_build_object('num', num, 'date', date, 'heure', to_char(heure,'HH24:MI'), 'client', acheteur,
                 'article', libelle, 'qte', quantite, 'montant', montant, 'mode', mode, 'annulee', annulee) order by date desc, num desc)
               from (select * from ventes where vendeur = a.nom and date >= deb order by date desc, num desc limit 300) s), '[]'));
end $$;

create or replace function public.api_admin_donnees(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  return jsonb_build_object('ok', true, 'moi', a.id,
    'utilisateurs', coalesce((select jsonb_agg(jsonb_build_object(
        'id', u.id, 'nom', u.nom, 'identifiant', u.identifiant, 'role', u.role, 'actif', u.actif,
        'doit_changer_pin', u.doit_changer_pin, 'bloque_jusqu', case when u.bloque_jusqu > now() then u.bloque_jusqu end,
        'derniere_connexion', u.derniere_connexion, 'cree_le', u.cree_le,
        'sessions', (select count(*) from sessions s where s.acces_id = u.id and s.expire_le > now()),
        'acces', coalesce((select jsonb_agg(substr(secteur, 10) order by secteur) from droits d where d.acces_id = u.id and secteur like 'boutique:%'), '[]'))
      order by u.role, u.nom) from acces u), '[]'),
    'journal', coalesce((select jsonb_agg(to_jsonb(j) order by j.quand desc) from (select * from journal order by quand desc limit 500) j), '[]'),
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres), '{}'));
end $$;

create or replace function public.api_admin_utilisateur(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; u public.acces; ident text; k text; nouveau boolean; ancien text;
        cles text[] := array['caisse','stocks','ventes','ventes_annuler','entrees','bilan','catalogue'];
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
    delete from droits where acces_id = u.id and secteur like 'boutique:%';
    for k in select jsonb_array_elements_text(p->'acces') loop
      if not k = any(cles) then return _err('Accès inconnu : ' || k); end if;
      insert into droits(acces_id, secteur, niveau) values (u.id, 'boutique:' || k, 'oui') on conflict do nothing;
    end loop;
  end if;
  perform _log(a, case when nouveau then 'Création d''utilisateur' else 'Modification d''utilisateur' end, u.identifiant,
               jsonb_build_object('nom', u.nom, 'role', u.role, 'actif', u.actif, 'acces', p->'acces')
               || case when ancien is not null and ancien <> u.identifiant then jsonb_build_object('ancien_identifiant', ancien) else '{}' end);
  return jsonb_build_object('ok', true, 'id', u.id);
end $$;

revoke execute on function public._a(public.acces, text), public._droits(public.acces), public._peut(public.acces, text, text) from public, anon, authenticated;
;
