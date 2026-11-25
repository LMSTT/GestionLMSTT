create or replace function public.api_donnees(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; nb text; lec boolean; ges boolean;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  nb := case when a.doit_changer_pin then 'aucun' else _niveau(a, 'boutique') end;
  lec := nb in ('lecture','gestion'); ges := nb = 'gestion';
  return jsonb_build_object(
    'ok', true, 'nom', a.nom, 'role', a.role, 'identifiant', a.identifiant, 'doit_changer_pin', a.doit_changer_pin,
    'droits', jsonb_build_object('boutique', nb, 'administration', case when a.role = 'admin' and not a.doit_changer_pin then 'gestion' else 'aucun' end),
    'catalogue', case when nb = 'aucun' then '[]'::jsonb else coalesce((select jsonb_agg(
        case when ges or lec then to_jsonb(c) else to_jsonb(c) - 'prix_achat' - 'description' end
        || jsonb_build_object('stock', _stock(c.ref)) order by c.categorie, c.designation, c.declinaison) from catalogue c), '[]') end,
    'ventes', case when lec then coalesce((select jsonb_agg(v order by v.date desc, v.num desc) from ventes v), '[]') else '[]' end,
    'entrees', case when lec then coalesce((select jsonb_agg(e order by e.date desc, e.id desc) from entrees e), '[]') else '[]' end,
    'ajustements', case when lec then coalesce((select jsonb_agg(j order by j.date desc, j.id desc) from ajustements j), '[]') else '[]' end,
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres where ges or cle = 'modes'), '{}')
  );
end $$;

create or replace function public.api_vente(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; l jsonb; c catalogue; n int; v_num text; nums text[] := '{}';
        q int; pv numeric; tot numeric := 0; d date; h time(0);
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _peut(a, 'boutique', 'saisie') then return _err('droits'); end if;
  if coalesce(trim(p->>'acheteur'),'') = '' then return _err('Indique le client.'); end if;
  if not exists (select 1 from parametres, jsonb_array_elements_text(valeurs) m where cle = 'modes' and m = p->>'mode') then
    return _err('Mode de règlement non autorisé.'); end if;
  if coalesce((p->>'confirme')::boolean, false) is not true then
    return _err('Coche la confirmation de dépôt / encaissement avant de valider.'); end if;
  if jsonb_typeof(p->'lignes') is distinct from 'array' or jsonb_array_length(p->'lignes') = 0 then return _err('Panier vide.'); end if;
  d := coalesce(nullif(p->>'date','')::date, (now() at time zone 'Europe/Paris')::date);
  h := coalesce(nullif(p->>'heure','')::time(0), (now() at time zone 'Europe/Paris')::time(0));
  perform pg_advisory_xact_lock(4242);
  for l in select jsonb_build_object('ref', x->>'ref', 'qte', sum((x->>'qte')::int)) from jsonb_array_elements(p->'lignes') x group by x->>'ref' loop
    select * into c from catalogue where ref = l->>'ref';
    if c.ref is null or c.statut <> 'Actif' then return _err('Article inconnu ou inactif : ' || coalesce(l->>'ref','?')); end if;
    if (l->>'qte')::int <= 0 then return _err('Quantité invalide.'); end if;
    if (l->>'qte')::int > _stock(c.ref) then return _err('Stock insuffisant pour ' || c.designation || ' (' || _stock(c.ref) || ' dispo).'); end if;
  end loop;
  select coalesce(max(substring(v.num from 2)::int),0) into n from ventes v where v.num ~ '^V[0-9]+$';
  for l in select * from jsonb_array_elements(p->'lignes') loop
    select * into c from catalogue where ref = l->>'ref';
    q := (l->>'qte')::int;
    pv := nullif(l->>'prix','')::numeric;
    if pv is not null and pv < 0 then return _err('Prix invalide.'); end if;
    n := n + 1; v_num := 'V' || lpad(n::text, 4, '0');
    insert into ventes(num, date, heure, acheteur, ref, libelle, quantite, pv_catalogue, pv_applique, montant, pa_unitaire, mode, vendeur, commentaire, encaissement_confirme)
    values (v_num, d, h, trim(p->>'acheteur'), c.ref,
            c.designation || case when c.declinaison <> '' then ' – ' || c.declinaison else '' end,
            q, c.prix_vente, pv, q * coalesce(pv, c.prix_vente), c.prix_achat, p->>'mode', a.nom, coalesce(trim(p->>'commentaire'),''), true);
    nums := nums || v_num; tot := tot + q * coalesce(pv, c.prix_vente);
  end loop;
  perform _log(a, 'Vente', array_to_string(nums, ', '), jsonb_build_object('client', trim(p->>'acheteur'), 'total', tot, 'mode', p->>'mode'));
  return jsonb_build_object('ok', true, 'nums', to_jsonb(nums), 'total', tot);
end $$;

drop function if exists public.api_annuler_vente(text, text);
create or replace function public.api_annuler_vente(p_pin text, p_num text, p_motif text default '')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; v ventes;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _peut(a, 'boutique', 'gestion') then return _err('droits'); end if;
  if coalesce(trim(p_motif),'') = '' then return _err('Indique le motif de l''annulation.'); end if;
  update ventes set annulee = true, annulee_le = now(), annulee_par = a.nom, motif_annulation = trim(p_motif)
   where num = p_num and not annulee returning * into v;
  if v.num is null then return _err('Vente introuvable ou déjà annulée.'); end if;
  perform _log(a, 'Annulation de vente', v.num, jsonb_build_object('client', v.acheteur, 'article', v.libelle, 'montant', v.montant, 'motif', trim(p_motif)));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_entree(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; i bigint;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _peut(a, 'boutique', 'gestion') then return _err('droits'); end if;
  if not exists (select 1 from catalogue where ref = p->>'ref') then return _err('Article inconnu.'); end if;
  if coalesce((p->>'quantite')::int,0) <= 0 then return _err('Quantité invalide.'); end if;
  insert into entrees(date, num_commande, fournisseur, ref, quantite, prix_achat, commentaire, saisi_par)
  values (coalesce(nullif(p->>'date','')::date, current_date), coalesce(p->>'num_commande',''), coalesce(p->>'fournisseur',''),
          p->>'ref', (p->>'quantite')::int, coalesce(nullif(p->>'prix_achat','')::numeric,0), coalesce(p->>'commentaire',''), a.nom)
  returning id into i;
  perform _log(a, 'Entrée de stock', p->>'ref', jsonb_build_object('id', i, 'quantite', (p->>'quantite')::int, 'commande', p->>'num_commande'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_ajustement(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; i bigint;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _peut(a, 'boutique', 'gestion') then return _err('droits'); end if;
  if not exists (select 1 from catalogue where ref = p->>'ref') then return _err('Article inconnu.'); end if;
  if coalesce((p->>'quantite')::int,0) = 0 then return _err('Quantité invalide.'); end if;
  if coalesce(p->>'motif','') = '' then return _err('Indique le motif.'); end if;
  insert into ajustements(date, ref, quantite, motif, commentaire, saisi_par)
  values (coalesce(nullif(p->>'date','')::date, current_date), p->>'ref', (p->>'quantite')::int, p->>'motif', coalesce(p->>'commentaire',''), a.nom)
  returning id into i;
  perform _log(a, 'Ajustement de stock', p->>'ref', jsonb_build_object('id', i, 'quantite', (p->>'quantite')::int, 'motif', p->>'motif'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_supprimer_mouvement(p_pin text, p_type text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; old jsonb;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _peut(a, 'boutique', 'gestion') then return _err('droits'); end if;
  if p_type = 'entree' then delete from entrees e where e.id = p_id returning to_jsonb(e) into old;
  elsif p_type = 'ajustement' then delete from ajustements j where j.id = p_id returning to_jsonb(j) into old;
  else return _err('Type inconnu.'); end if;
  if old is null then return _err('Mouvement introuvable.'); end if;
  perform _log(a, 'Suppression ' || case when p_type = 'entree' then 'd''entrée' else 'd''ajustement' end, old->>'ref', old);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_article(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; r text; rp text; dc text; avant jsonb;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _peut(a, 'boutique', 'gestion') then return _err('droits'); end if;
  if coalesce(trim(p->>'designation'),'') = '' then return _err('Désignation requise.'); end if;
  r := nullif(p->>'ref','');
  if r is null then
    rp := upper(regexp_replace(trim(coalesce(p->>'ref_principale','')), '[^A-Za-z0-9-]+', '-', 'g'));
    if rp = '' then return _err('Référence requise.'); end if;
    dc := trim(coalesce(p->>'declinaison',''));
    r := rp || case when dc <> '' then '-' || regexp_replace(dc, '[^A-Za-z0-9-]+', '-', 'g') else '' end;
    if exists (select 1 from catalogue where ref = r) then return _err('Cette référence existe déjà.'); end if;
    insert into catalogue(ref, ref_principale, declinaison, designation, categorie, description, fournisseur, prix_achat, prix_vente, seuil, statut)
    values (r, rp, dc, trim(p->>'designation'), coalesce(p->>'categorie',''), coalesce(p->>'description',''), coalesce(p->>'fournisseur',''),
            coalesce(nullif(p->>'prix_achat','')::numeric,0), coalesce(nullif(p->>'prix_vente','')::numeric,0),
            coalesce(nullif(p->>'seuil','')::int,0), coalesce(nullif(p->>'statut',''),'Actif'));
    perform _log(a, 'Création d''article', r, p);
  else
    select to_jsonb(c) into avant from catalogue c where ref = r;
    if avant is null then return _err('Article introuvable.'); end if;
    update catalogue set designation = trim(p->>'designation'), categorie = coalesce(p->>'categorie', categorie),
      description = coalesce(p->>'description', description), fournisseur = coalesce(p->>'fournisseur', fournisseur),
      prix_achat = coalesce(nullif(p->>'prix_achat','')::numeric, prix_achat), prix_vente = coalesce(nullif(p->>'prix_vente','')::numeric, prix_vente),
      seuil = coalesce(nullif(p->>'seuil','')::int, seuil), statut = coalesce(nullif(p->>'statut',''), statut), maj_le = now()
    where ref = r;
    perform _log(a, 'Modification d''article', r, jsonb_build_object('avant', jsonb_build_object('prix_vente', avant->'prix_vente', 'prix_achat', avant->'prix_achat', 'statut', avant->'statut', 'seuil', avant->'seuil'),
                                                                        'apres', jsonb_build_object('prix_vente', p->'prix_vente', 'prix_achat', p->'prix_achat', 'statut', p->'statut', 'seuil', p->'seuil')));
  end if;
  return jsonb_build_object('ok', true, 'ref', r);
end $$;

create or replace function public.api_compte(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; deb date; today date := (now() at time zone 'Europe/Paris')::date;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  deb := make_date(extract(year from today)::int - case when extract(month from today) >= 8 then 0 else 1 end, 8, 1);
  return jsonb_build_object('ok', true, 'nom', a.nom, 'identifiant', a.identifiant, 'role', a.role, 'doit_changer_pin', a.doit_changer_pin,
    'droits', jsonb_build_object('boutique', _niveau(a,'boutique'), 'administration', case when a.role = 'admin' then 'gestion' else 'aucun' end),
    'derniere_connexion', a.derniere_connexion,
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
;
