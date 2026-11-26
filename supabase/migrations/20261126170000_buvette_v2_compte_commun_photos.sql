-- Buvette V2 : compte commun « Utilisateur Buvette », administration réservée aux admins, photos produits
alter table public.bv_produits add column if not exists photo text not null default '';

-- Responsable buvette = administrateur uniquement (plus de droit « responsable » ni de code responsable)
create or replace function public._b(a public.acces, p_cle text)
returns boolean language sql stable security definer set search_path = public as $$
  select a.id is not null and a.actif and not a.doit_changer_pin
     and (a.role = 'admin' or (p_cle = 'caisse' and exists (select 1 from droits where acces_id = a.id and secteur = 'buvette:caisse')))
$$;
create or replace function public._bresp(a public.acces, p_pin text)
returns boolean language sql stable security definer set search_path = public as $$
  select a.id is not null and a.actif and not a.doit_changer_pin and a.role = 'admin'
$$;
create or replace function public.api_bv_resp(p_pin text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin return _err('La gestion de la buvette est réservée aux administrateurs.'); end $$;
delete from droits where secteur = 'buvette:responsable';
delete from secrets where cle = 'buvette_responsable';
update sessions set resp_jusqu = null;

-- Produits : photo (image compressée en data URL, 200 Ko max)
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
  return jsonb_build_object('ok', true, 'id', i);
end $$;

-- Compte commun « Utilisateur Buvette » (identifiant : buvette, PIN : 1976), caisse seulement
insert into acces(nom, role, identifiant, pin_hash, doit_changer_pin)
select 'Utilisateur Buvette', 'utilisateur', 'buvette', extensions.crypt('1976', extensions.gen_salt('bf')), false
where not exists (select 1 from acces where lower(identifiant) = 'buvette');
insert into droits(acces_id, secteur, niveau)
select id, 'buvette:caisse', 'oui' from acces where lower(identifiant) = 'buvette'
on conflict do nothing;
