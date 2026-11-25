-- ===== Fonctions internes =====
create or replace function public._acces(p_pin text)
returns public.acces language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; nb int;
begin
  select count(*) into nb from tentatives where not ok and quand > now() - interval '15 minutes';
  if nb >= 15 then return null; end if;
  select * into a from acces where actif and pin_hash = crypt(coalesce(p_pin,''), pin_hash) limit 1;
  insert into tentatives(ok) values (a.id is not null);
  delete from tentatives where quand < now() - interval '1 day';
  return a;
end $$;

create or replace function public._err(msg text)
returns jsonb language sql immutable as $$ select jsonb_build_object('ok', false, 'erreur', msg) $$;

create or replace function public._stock(p_ref text)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select stock_initial from catalogue where ref = p_ref),0)
       + coalesce((select sum(quantite) from entrees where ref = p_ref),0)
       - coalesce((select sum(quantite) from ventes where ref = p_ref),0)
       + coalesce((select sum(quantite) from ajustements where ref = p_ref),0)
$$;

-- ===== API publique (appelée par la page) =====
create or replace function public.api_ping()
returns int language sql stable security definer set search_path = public as $$ select count(*)::int from catalogue $$;

create or replace function public.api_connexion(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('PIN incorrect (ou trop d''essais : patiente 15 min)'); end if;
  return jsonb_build_object('ok', true, 'nom', a.nom, 'role', a.role);
end $$;

create or replace function public.api_donnees(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('PIN incorrect (ou trop d''essais : patiente 15 min)'); end if;
  return jsonb_build_object(
    'ok', true, 'nom', a.nom, 'role', a.role,
    'catalogue', coalesce((select jsonb_agg(c order by c.categorie, c.designation, c.declinaison) from catalogue c), '[]'),
    'ventes', coalesce((select jsonb_agg(v order by v.date desc, v.num desc) from ventes v), '[]'),
    'entrees', coalesce((select jsonb_agg(e order by e.date desc, e.id desc) from entrees e), '[]'),
    'ajustements', coalesce((select jsonb_agg(j order by j.date desc, j.id desc) from ajustements j), '[]'),
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres), '{}')
  );
end $$;

create or replace function public.api_vente(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; l jsonb; c catalogue; n int; num text; nums text[] := '{}';
        q int; pv numeric; tot numeric := 0; d date;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('PIN incorrect (ou trop d''essais : patiente 15 min)'); end if;
  if coalesce(trim(p->>'acheteur'),'') = '' then return _err('Indique l''acheteur.'); end if;
  if coalesce(p->>'mode','') not in ('Espèces','Carte bancaire') then return _err('Règlement : Espèces ou Carte bancaire uniquement.'); end if;
  if coalesce(trim(p->>'vendeur'),'') = '' then return _err('Indique le vendeur.'); end if;
  if jsonb_typeof(p->'lignes') <> 'array' or jsonb_array_length(p->'lignes') = 0 then return _err('Panier vide.'); end if;
  d := coalesce(nullif(p->>'date','')::date, current_date);
  perform pg_advisory_xact_lock(4242);
  -- contrôle du stock par article (quantités cumulées du panier)
  for l in select jsonb_build_object('ref', x->>'ref', 'qte', sum((x->>'qte')::int)) from jsonb_array_elements(p->'lignes') x group by x->>'ref' loop
    select * into c from catalogue where ref = l->>'ref';
    if c.ref is null or c.statut <> 'Actif' then return _err('Article inconnu ou inactif : ' || coalesce(l->>'ref','?')); end if;
    if (l->>'qte')::int <= 0 then return _err('Quantité invalide.'); end if;
    if (l->>'qte')::int > _stock(c.ref) then return _err('Stock insuffisant pour ' || c.designation || ' (' || _stock(c.ref) || ' dispo).'); end if;
  end loop;
  select coalesce(max(substring(num from 2)::int),0) into n from ventes where num ~ '^V[0-9]+$';
  for l in select * from jsonb_array_elements(p->'lignes') loop
    select * into c from catalogue where ref = l->>'ref';
    q := (l->>'qte')::int;
    pv := nullif(l->>'prix','')::numeric;
    if pv is not null and pv < 0 then return _err('Prix invalide.'); end if;
    n := n + 1; num := 'V' || lpad(n::text, 4, '0');
    insert into ventes(num, date, acheteur, ref, libelle, quantite, pv_catalogue, pv_applique, montant, pa_unitaire, mode, vendeur, commentaire)
    values (num, d, trim(p->>'acheteur'), c.ref,
            c.designation || case when c.declinaison <> '' then ' – ' || c.declinaison else '' end,
            q, c.prix_vente, pv, q * coalesce(pv, c.prix_vente), c.prix_achat, p->>'mode', trim(p->>'vendeur'), coalesce(trim(p->>'commentaire'),''));
    nums := nums || num; tot := tot + q * coalesce(pv, c.prix_vente);
  end loop;
  return jsonb_build_object('ok', true, 'nums', to_jsonb(nums), 'total', tot);
end $$;

create or replace function public.api_annuler_vente(p_pin text, p_num text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('PIN incorrect (ou trop d''essais : patiente 15 min)'); end if;
  if a.role <> 'admin' then return _err('Réservé au responsable boutique.'); end if;
  delete from ventes where num = p_num;
  if not found then return _err('Vente introuvable.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_entree(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('PIN incorrect (ou trop d''essais : patiente 15 min)'); end if;
  if a.role <> 'admin' then return _err('Réservé au responsable boutique.'); end if;
  if not exists (select 1 from catalogue where ref = p->>'ref') then return _err('Article inconnu.'); end if;
  if coalesce((p->>'quantite')::int,0) <= 0 then return _err('Quantité invalide.'); end if;
  insert into entrees(date, num_commande, fournisseur, ref, quantite, prix_achat, commentaire, saisi_par)
  values (coalesce(nullif(p->>'date','')::date, current_date), coalesce(p->>'num_commande',''), coalesce(p->>'fournisseur',''),
          p->>'ref', (p->>'quantite')::int, coalesce(nullif(p->>'prix_achat','')::numeric,0), coalesce(p->>'commentaire',''), a.nom);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_ajustement(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('PIN incorrect (ou trop d''essais : patiente 15 min)'); end if;
  if a.role <> 'admin' then return _err('Réservé au responsable boutique.'); end if;
  if not exists (select 1 from catalogue where ref = p->>'ref') then return _err('Article inconnu.'); end if;
  if coalesce((p->>'quantite')::int,0) = 0 then return _err('Quantité invalide.'); end if;
  if coalesce(p->>'motif','') = '' then return _err('Indique le motif.'); end if;
  insert into ajustements(date, ref, quantite, motif, commentaire, saisi_par)
  values (coalesce(nullif(p->>'date','')::date, current_date), p->>'ref', (p->>'quantite')::int, p->>'motif', coalesce(p->>'commentaire',''), a.nom);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_supprimer_mouvement(p_pin text, p_type text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('PIN incorrect (ou trop d''essais : patiente 15 min)'); end if;
  if a.role <> 'admin' then return _err('Réservé au responsable boutique.'); end if;
  if p_type = 'entree' then delete from entrees where id = p_id;
  elsif p_type = 'ajustement' then delete from ajustements where id = p_id;
  else return _err('Type inconnu.'); end if;
  if not found then return _err('Mouvement introuvable.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_article(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; r text; rp text; dc text;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('PIN incorrect (ou trop d''essais : patiente 15 min)'); end if;
  if a.role <> 'admin' then return _err('Réservé au responsable boutique.'); end if;
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
  else
    update catalogue set designation = trim(p->>'designation'), categorie = coalesce(p->>'categorie', categorie),
      description = coalesce(p->>'description', description), fournisseur = coalesce(p->>'fournisseur', fournisseur),
      prix_achat = coalesce(nullif(p->>'prix_achat','')::numeric, prix_achat), prix_vente = coalesce(nullif(p->>'prix_vente','')::numeric, prix_vente),
      seuil = coalesce(nullif(p->>'seuil','')::int, seuil), statut = coalesce(nullif(p->>'statut',''), statut), maj_le = now()
    where ref = r;
    if not found then return _err('Article introuvable.'); end if;
  end if;
  return jsonb_build_object('ok', true, 'ref', r);
end $$;

-- ===== Droits =====
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.api_ping(), public.api_connexion(text), public.api_donnees(text),
  public.api_vente(text, jsonb), public.api_annuler_vente(text, text), public.api_entree(text, jsonb),
  public.api_ajustement(text, jsonb), public.api_supprimer_mouvement(text, text, bigint), public.api_article(text, jsonb)
  to anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

;
