create or replace function public._est_admin(a public.acces)
returns boolean language sql stable as $$ select a.id is not null and a.actif and a.role = 'admin' and not a.doit_changer_pin $$;

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
        'droits', coalesce((select jsonb_object_agg(secteur, niveau) from droits d where d.acces_id = u.id), '{}'))
      order by u.role, u.nom) from acces u), '[]'),
    'journal', coalesce((select jsonb_agg(to_jsonb(j) order by j.quand desc) from (select * from journal order by quand desc limit 500) j), '[]'),
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres), '{}'));
end $$;

-- Créer ou modifier un utilisateur
create or replace function public.api_admin_utilisateur(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; u public.acces; ident text; k text; v text; nouveau boolean;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  if coalesce(trim(p->>'nom'),'') = '' then return _err('Indique le nom.'); end if;
  if coalesce(p->>'role','utilisateur') not in ('admin','utilisateur') then return _err('Profil inconnu.'); end if;
  nouveau := nullif(p->>'id','') is null;
  if nouveau then
    ident := lower(trim(coalesce(p->>'identifiant','')));
    if ident !~ '^[a-z0-9._-]{2,30}$' then return _err('Identifiant : 2 à 30 caractères, lettres sans accent, chiffres, point ou tiret.'); end if;
    if exists (select 1 from acces where lower(identifiant) = ident) then return _err('Cet identifiant existe déjà.'); end if;
    if coalesce(p->>'pin','') !~ '^[0-9]{4}$' then return _err('Code provisoire : 4 chiffres.'); end if;
    insert into acces(nom, role, identifiant, pin_hash, doit_changer_pin)
    values (trim(p->>'nom'), coalesce(p->>'role','utilisateur'), ident, crypt(p->>'pin', gen_salt('bf')), true) returning * into u;
  else
    select * into u from acces where id = (p->>'id')::bigint;
    if u.id is null then return _err('Utilisateur introuvable.'); end if;
    if u.id = a.id and (coalesce(p->>'role','admin') <> 'admin' or coalesce((p->>'actif')::boolean, true) = false) then
      return _err('Tu ne peux pas retirer ton propre accès administrateur.'); end if;
    update acces set nom = trim(p->>'nom'), role = coalesce(p->>'role', role), actif = coalesce((p->>'actif')::boolean, actif),
      bloque_jusqu = case when coalesce((p->>'debloquer')::boolean,false) then null else bloque_jusqu end,
      echecs = case when coalesce((p->>'debloquer')::boolean,false) then 0 else echecs end
     where id = u.id returning * into u;
    if not u.actif then delete from sessions where acces_id = u.id; end if;
  end if;
  if jsonb_typeof(p->'droits') = 'object' then
    for k, v in select key, value from jsonb_each_text(p->'droits') loop
      if k not in ('boutique') or v not in ('aucun','lecture','saisie','gestion') then return _err('Droit invalide : ' || k); end if;
      insert into droits(acces_id, secteur, niveau) values (u.id, k, v)
      on conflict (acces_id, secteur) do update set niveau = excluded.niveau;
    end loop;
  end if;
  perform _log(a, case when nouveau then 'Création d''utilisateur' else 'Modification d''utilisateur' end, u.identifiant,
               jsonb_build_object('nom', u.nom, 'role', u.role, 'actif', u.actif, 'droits', p->'droits'));
  return jsonb_build_object('ok', true, 'id', u.id);
end $$;

create or replace function public.api_admin_reset_pin(p_pin text, p_id bigint, p_nouveau text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; u public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  if coalesce(p_nouveau,'') !~ '^[0-9]{4}$' then return _err('Code provisoire : 4 chiffres.'); end if;
  update acces set pin_hash = crypt(p_nouveau, gen_salt('bf')), doit_changer_pin = (id <> a.id), echecs = 0, bloque_jusqu = null
   where id = p_id returning * into u;
  if u.id is null then return _err('Utilisateur introuvable.'); end if;
  if u.id <> a.id then delete from sessions where acces_id = u.id; end if;
  perform _log(a, 'Réinitialisation de code PIN', u.identifiant);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_admin_fermer_sessions(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; u public.acces; n int;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  select * into u from acces where id = p_id;
  if u.id is null then return _err('Utilisateur introuvable.'); end if;
  delete from sessions where acces_id = u.id and token <> substr(p_pin,3)::uuid;
  get diagnostics n = row_count;
  perform _log(a, 'Déconnexion forcée', u.identifiant, jsonb_build_object('sessions', n));
  return jsonb_build_object('ok', true, 'sessions', n);
end $$;

create or replace function public.api_admin_parametre(p_pin text, p_cle text, p_valeurs jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; avant jsonb;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  if p_cle not in ('modes','categories','fournisseurs','motifs') then return _err('Paramètre inconnu.'); end if;
  if jsonb_typeof(p_valeurs) <> 'array' or jsonb_array_length(p_valeurs) = 0 then return _err('La liste ne peut pas être vide.'); end if;
  if exists (select 1 from jsonb_array_elements(p_valeurs) x where jsonb_typeof(x) <> 'string' or trim(x #>> '{}') = '') then return _err('Valeurs invalides.'); end if;
  select valeurs into avant from parametres where cle = p_cle;
  insert into parametres(cle, valeurs) values (p_cle, p_valeurs) on conflict (cle) do update set valeurs = excluded.valeurs;
  perform _log(a, 'Modification de paramètre', p_cle, jsonb_build_object('avant', avant, 'apres', p_valeurs));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_admin_export(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  perform _log(a, 'Export de sauvegarde');
  return jsonb_build_object('ok', true, 'exporte_le', now(),
    'catalogue', coalesce((select jsonb_agg(c) from catalogue c), '[]'),
    'ventes', coalesce((select jsonb_agg(v order by v.num) from ventes v), '[]'),
    'entrees', coalesce((select jsonb_agg(e order by e.id) from entrees e), '[]'),
    'ajustements', coalesce((select jsonb_agg(j order by j.id) from ajustements j), '[]'),
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres), '{}'),
    'utilisateurs', coalesce((select jsonb_agg(jsonb_build_object('nom', nom, 'identifiant', identifiant, 'role', role, 'actif', actif)) from acces), '[]'),
    'droits', coalesce((select jsonb_agg(jsonb_build_object('identifiant', ac.identifiant, 'secteur', d.secteur, 'niveau', d.niveau)) from droits d join acces ac on ac.id = d.acces_id), '[]'),
    'journal', coalesce((select jsonb_agg(j order by j.id) from journal j), '[]'));
end $$;

-- ===== Droits d'exécution =====
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.api_ping(), public.api_identifiants(),
  public.api_connexion(text, text, boolean), public.api_deconnexion(text), public.api_changer_pin(text, text, text),
  public.api_donnees(text), public.api_compte(text),
  public.api_vente(text, jsonb), public.api_annuler_vente(text, text, text), public.api_entree(text, jsonb),
  public.api_ajustement(text, jsonb), public.api_supprimer_mouvement(text, text, bigint), public.api_article(text, jsonb),
  public.api_admin_donnees(text), public.api_admin_utilisateur(text, jsonb), public.api_admin_reset_pin(text, bigint, text),
  public.api_admin_fermer_sessions(text, bigint), public.api_admin_parametre(text, text, jsonb), public.api_admin_export(text)
to anon, authenticated;
;
