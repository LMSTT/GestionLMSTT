-- Tarifs des produits par type d'événement (Buvette semaine, Pro A, Tournoi, Compétition).
-- Sans tarif spécifique : prix de vente par défaut. Le prix est fixé côté serveur.
create table if not exists public.bv_tarifs (
  produit_id bigint not null references public.bv_produits(id) on delete cascade,
  type text not null check (type in ('Buvette semaine','Pro A','Tournoi','Compétition')),
  prix numeric(10,2) not null check (prix >= 0),
  primary key (produit_id, type)
);
alter table public.bv_tarifs enable row level security;
revoke all on public.bv_tarifs from anon, authenticated;

create or replace function public.api_bv_donnees(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; resp boolean; so jsonb;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not (_b(a,'caisse') or _b(a,'responsable')) then return _err('droits'); end if;
  resp := _bresp(a, p_pin); so := _bv_session_ouverte();
  return jsonb_build_object('ok', true, 'nom', a.nom, 'caisse', _b(a,'caisse') or _b(a,'responsable'), 'resp', resp,
    'resp_permanent', _b(a,'responsable'),
    'resp_jusqu', (select resp_jusqu from sessions where token = substr(p_pin,3)::uuid),
    'categories', coalesce((select jsonb_agg(c order by c.ordre, c.nom) from bv_categories c where c.actif or resp), '[]'),
    'produits', coalesce((select jsonb_agg((case when resp then to_jsonb(p) else to_jsonb(p) - 'prix_achat' end) || jsonb_build_object('tarifs', coalesce((select jsonb_object_agg(t.type, t.prix) from bv_tarifs t where t.produit_id = p.id), '{}')) order by p.ordre, p.nom)
                          from bv_produits p where p.actif or resp), '[]'),
    'vendeurs', coalesce((select jsonb_agg(v order by v.prenom) from bv_vendeurs v where v.actif or resp), '[]'),
    'session', so,
    'ventes', case when resp and so is not null then coalesce((select jsonb_agg(to_jsonb(v) || jsonb_build_object('lignes',
                 (select jsonb_agg(jsonb_build_object('nom', l.nom, 'qte', l.qte, 'prix', l.prix_vente)) from bv_lignes l where l.vente_id = v.id))
               order by v.vendue_le desc) from bv_ventes v where v.session_id = (so->>'id')::bigint), '[]') else '[]' end,
    'sessions_recentes', case when resp then coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'statut', s.statut, 'ouverte_le', s.ouverte_le,
                 'cloturee_le', s.cloturee_le, 'evenement', e.type || case when e.adversaire <> '' then ' – ' || e.adversaire when e.libelle <> '' then ' – ' || e.libelle else '' end,
                 'date', e.date) order by s.ouverte_le desc) from (select * from bv_sessions order by ouverte_le desc limit 20) s join bv_evenements e on e.id = s.evenement_id), '[]') else '[]' end
  );
end $$;


create or replace function public.api_bv_ventes(p_pin text, p_ventes jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ty text; a public.acces; v jsonb; l jsonb; pr bv_produits; tot numeric; va numeric; ok text[] := '{}'; ko jsonb := '[]'; vid uuid; sid bigint; m text;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not (_b(a,'caisse') or _b(a,'responsable')) then return _err('droits'); end if;
  if jsonb_typeof(p_ventes) <> 'array' then return _err('Format invalide.'); end if;
  for v in select * from jsonb_array_elements(p_ventes) loop
    begin
      vid := (v->>'id')::uuid;
      if exists (select 1 from bv_ventes where id = vid) then ok := ok || vid::text; continue; end if;
      sid := (v->>'session_id')::bigint; m := v->>'mode';
      if not exists (select 1 from bv_sessions where id = sid) then raise exception 'Session inconnue'; end if;
      select e.type into ty from bv_sessions s join bv_evenements e on e.id = s.evenement_id where s.id = sid;
      if m not in ('especes','cb','offert') then raise exception 'Mode inconnu'; end if;
      if coalesce(trim(v->>'vendeur'),'') = '' then raise exception 'Vendeur manquant'; end if;
      if m = 'offert' and coalesce(v->>'beneficiaire_type','') not in ('Staff','Joueur') then raise exception 'Bénéficiaire manquant'; end if;
      if jsonb_typeof(v->'lignes') <> 'array' or jsonb_array_length(v->'lignes') = 0 then raise exception 'Panier vide'; end if;
      tot := 0; va := 0;
      for l in select * from jsonb_array_elements(v->'lignes') loop
        select * into pr from bv_produits where id = (l->>'produit_id')::bigint;
        if pr.id is null then raise exception 'Produit inconnu'; end if;
        if (l->>'qte')::int <= 0 then raise exception 'Quantité invalide'; end if;
        tot := tot + (l->>'qte')::int * coalesce((select t.prix from bv_tarifs t where t.produit_id = pr.id and t.type = ty), pr.prix_vente);
        va := va + (l->>'qte')::int * pr.prix_achat;
      end loop;
      insert into bv_ventes(id, session_id, vendeur, vendue_le, mode, total, valeur_achat, recu, rendu, beneficiaire_type, beneficiaire_nom, poste)
      values (vid, sid, trim(v->>'vendeur'), coalesce(nullif(v->>'vendue_le','')::timestamptz, now()), m,
              case when m = 'offert' then 0 else tot end, va,
              case when m = 'especes' then nullif(v->>'recu','')::numeric end,
              case when m = 'especes' then nullif(v->>'recu','')::numeric - tot end,
              case when m = 'offert' then v->>'beneficiaire_type' end, trim(coalesce(v->>'beneficiaire_nom','')), a.identifiant);
      for l in select * from jsonb_array_elements(v->'lignes') loop
        select * into pr from bv_produits where id = (l->>'produit_id')::bigint;
        insert into bv_lignes(vente_id, produit_id, nom, qte, prix_vente, prix_achat)
        values (vid, pr.id, pr.nom, (l->>'qte')::int, coalesce((select t.prix from bv_tarifs t where t.produit_id = pr.id and t.type = ty), pr.prix_vente), pr.prix_achat);
      end loop;
      ok := ok || vid::text;
    exception when others then
      ko := ko || jsonb_build_object('id', v->>'id', 'erreur', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('ok', true, 'acceptees', to_jsonb(ok), 'refusees', ko);
end $$;


create or replace function public.api_bv_produit(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; i bigint; st int; ph text;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _bresp(a, p_pin) then return _err('droits'); end if;
  if coalesce(trim(p->>'nom'),'') = '' then return _err('Nom du produit requis.'); end if;
  if coalesce(nullif(p->>'prix_vente','')::numeric, -1) < 0 then return _err('Prix de vente requis.'); end if;
  ph := p->>'photo';
  if ph is not null and ph <> '' and (ph !~ '^data:image/(jpeg|png|webp);base64,' or length(ph) > 200000) then return _err('Photo invalide ou trop lourde.'); end if;
  if nullif(p->>'id','') is null then
    insert into bv_produits(categorie_id, nom, prix_vente, prix_achat, seuil, actif, ordre, photo)
    values (nullif(p->>'categorie_id','')::bigint, trim(p->>'nom'), (p->>'prix_vente')::numeric, coalesce(nullif(p->>'prix_achat','')::numeric,0),
            coalesce(nullif(p->>'seuil','')::int,0), coalesce((p->>'actif')::boolean, true), coalesce(nullif(p->>'ordre','')::int,0), coalesce(ph,''))
    returning id into i;
    st := coalesce(nullif(p->>'stock','')::int, 0);
    if st <> 0 then insert into bv_mouvements(produit_id, type, qte, motif, par) values (i, 'stock initial', st, '', a.nom); end if;
    perform _log(a, 'Buvette : création de produit', trim(p->>'nom'), p - 'photo');
  else
    i := (p->>'id')::bigint;
    update bv_produits set categorie_id = nullif(p->>'categorie_id','')::bigint, nom = trim(p->>'nom'), prix_vente = (p->>'prix_vente')::numeric,
      prix_achat = coalesce(nullif(p->>'prix_achat','')::numeric, prix_achat), seuil = coalesce(nullif(p->>'seuil','')::int, seuil),
      actif = coalesce((p->>'actif')::boolean, actif), ordre = coalesce(nullif(p->>'ordre','')::int, ordre),
      photo = coalesce(ph, photo), maj_le = now()
     where id = i;
    if not found then return _err('Produit introuvable.'); end if;
    perform _log(a, 'Buvette : modification de produit', trim(p->>'nom'), p - 'photo');
  end if;
  if jsonb_typeof(p->'tarifs') = 'object' then
    delete from bv_tarifs where produit_id = i;
    insert into bv_tarifs(produit_id, type, prix)
    select i, k, replace(v,',','.')::numeric from jsonb_each_text(p->'tarifs') x(k, v)
     where k in ('Buvette semaine','Pro A','Tournoi','Compétition') and coalesce(trim(v),'') <> '' and replace(v,',','.')::numeric >= 0;
  end if;
  return jsonb_build_object('ok', true, 'id', i);
end $$;

