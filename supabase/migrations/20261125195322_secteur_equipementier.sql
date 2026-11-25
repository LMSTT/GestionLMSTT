create table public.equip_saisons (
  saison text primary key check (saison ~ '^[0-9]{4}-[0-9]{4}$'),
  dotation numeric(10,2) not null default 0,
  objectif_ca numeric(10,2) not null default 0,
  notes text not null default ''
);
create table public.equip_ca (
  id bigint generated always as identity primary key,
  saison text not null references public.equip_saisons(saison) on update cascade,
  mois date not null,
  montant numeric(10,2) not null,
  nb_commandes int,
  commentaire text not null default '',
  saisi_par text not null default '',
  cree_le timestamptz not null default now()
);
create table public.equip_dotations (
  id bigint generated always as identity primary key,
  saison text not null references public.equip_saisons(saison) on update cascade,
  date date not null,
  categorie text not null,
  designation text not null,
  quantite numeric(10,2) not null default 1,
  valeur numeric(10,2) not null default 0,
  statut text not null default 'Demandé' check (statut in ('Demandé','Commandé','Reçu')),
  commentaire text not null default '',
  saisi_par text not null default '',
  cree_le timestamptz not null default now()
);
alter table public.equip_saisons enable row level security;
alter table public.equip_ca enable row level security;
alter table public.equip_dotations enable row level security;
revoke all on public.equip_saisons, public.equip_ca, public.equip_dotations from anon, authenticated;

insert into public.equip_saisons(saison, dotation, notes) values ('2026-2027', 15000, 'Dotation Tibhar / Dauphin (montant à vérifier dans la convention)');
insert into public.parametres(cle, valeurs) values ('equip_categories', '["Balles","Filets","Tables","Textile","Matériel","Autre"]') on conflict do nothing;

-- accès explicite uniquement (pas automatique pour les administrateurs)
insert into public.droits(acces_id, secteur, niveau) select id, 'equipementier', 'oui' from public.acces where identifiant = 'jerome';

create or replace function public._equip(a public.acces)
returns boolean language sql stable security definer set search_path = public as $$
  select a.id is not null and a.actif and not a.doit_changer_pin and exists (select 1 from droits where acces_id = a.id and secteur = 'equipementier')
$$;

create or replace function public._droits(a public.acces)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'caisse', _a(a,'caisse'), 'stocks', _a(a,'stocks'), 'ventes', _a(a,'ventes'), 'ventes_annuler', _a(a,'ventes_annuler'),
    'entrees', _a(a,'entrees'), 'bilan', _a(a,'bilan'), 'catalogue', _a(a,'catalogue'),
    'administration', a.role = 'admin' and a.actif and not a.doit_changer_pin,
    'equipementier', _equip(a))
$$;

create or replace function public.api_equip_donnees(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _equip(a) then return _err('droits'); end if;
  return jsonb_build_object('ok', true,
    'saisons', coalesce((select jsonb_agg(s order by s.saison desc) from equip_saisons s), '[]'),
    'ca', coalesce((select jsonb_agg(c order by c.mois desc, c.id desc) from equip_ca c), '[]'),
    'dotations', coalesce((select jsonb_agg(d order by d.date desc, d.id desc) from equip_dotations d), '[]'),
    'achats_boutique', coalesce((select jsonb_agg(jsonb_build_object('date', e.date, 'montant', e.quantite * e.prix_achat)) from entrees e where e.fournisseur ilike '%dauphin%'), '[]'),
    'categories', coalesce((select valeurs from parametres where cle = 'equip_categories'), '[]'));
end $$;

create or replace function public.api_equip_saison(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _equip(a) then return _err('droits'); end if;
  if coalesce(p->>'saison','') !~ '^[0-9]{4}-[0-9]{4}$' then return _err('Saison au format 2026-2027.'); end if;
  insert into equip_saisons(saison, dotation, objectif_ca, notes)
  values (p->>'saison', coalesce(nullif(p->>'dotation','')::numeric,0), coalesce(nullif(p->>'objectif_ca','')::numeric,0), coalesce(p->>'notes',''))
  on conflict (saison) do update set dotation = excluded.dotation, objectif_ca = excluded.objectif_ca, notes = excluded.notes;
  perform _log(a, 'Équipementier : saison', p->>'saison', jsonb_build_object('objectif_ca', p->>'objectif_ca'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_equip_ca(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; m date; s text;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _equip(a) then return _err('droits'); end if;
  begin m := date_trunc('month', (p->>'mois' || '-01')::date)::date; exception when others then return _err('Mois invalide.'); end;
  s := case when extract(month from m) >= 8 then extract(year from m)::int || '-' || (extract(year from m)::int + 1) else (extract(year from m)::int - 1) || '-' || extract(year from m)::int end;
  if coalesce(nullif(p->>'montant','')::numeric, -1) < 0 then return _err('Montant invalide.'); end if;
  insert into equip_saisons(saison) values (s) on conflict do nothing;
  if nullif(p->>'id','') is null then
    insert into equip_ca(saison, mois, montant, nb_commandes, commentaire, saisi_par)
    values (s, m, (p->>'montant')::numeric, nullif(p->>'nb_commandes','')::int, coalesce(p->>'commentaire',''), a.nom);
  else
    update equip_ca set saison = s, mois = m, montant = (p->>'montant')::numeric, nb_commandes = nullif(p->>'nb_commandes','')::int, commentaire = coalesce(p->>'commentaire','')
     where id = (p->>'id')::bigint;
  end if;
  perform _log(a, 'Équipementier : CA Dauphin', to_char(m, 'MM/YYYY'), jsonb_build_object('montant', p->>'montant'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_equip_dotation(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; d date; s text;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _equip(a) then return _err('droits'); end if;
  d := coalesce(nullif(p->>'date','')::date, current_date);
  s := coalesce(nullif(p->>'saison',''), case when extract(month from d) >= 8 then extract(year from d)::int || '-' || (extract(year from d)::int + 1) else (extract(year from d)::int - 1) || '-' || extract(year from d)::int end);
  if coalesce(trim(p->>'designation'),'') = '' then return _err('Désignation requise.'); end if;
  if coalesce(p->>'statut','Demandé') not in ('Demandé','Commandé','Reçu') then return _err('Statut invalide.'); end if;
  insert into equip_saisons(saison) values (s) on conflict do nothing;
  if nullif(p->>'id','') is null then
    insert into equip_dotations(saison, date, categorie, designation, quantite, valeur, statut, commentaire, saisi_par)
    values (s, d, coalesce(nullif(p->>'categorie',''),'Autre'), trim(p->>'designation'), coalesce(nullif(p->>'quantite','')::numeric,1),
            coalesce(nullif(p->>'valeur','')::numeric,0), coalesce(p->>'statut','Demandé'), coalesce(p->>'commentaire',''), a.nom);
  else
    update equip_dotations set saison = s, date = d, categorie = coalesce(nullif(p->>'categorie',''),'Autre'), designation = trim(p->>'designation'),
      quantite = coalesce(nullif(p->>'quantite','')::numeric,1), valeur = coalesce(nullif(p->>'valeur','')::numeric,0),
      statut = coalesce(p->>'statut','Demandé'), commentaire = coalesce(p->>'commentaire','')
     where id = (p->>'id')::bigint;
  end if;
  perform _log(a, 'Équipementier : dotation', trim(p->>'designation'), jsonb_build_object('valeur', p->>'valeur', 'statut', p->>'statut'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_equip_suppr(p_pin text, p_type text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; old jsonb;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _equip(a) then return _err('droits'); end if;
  if p_type = 'ca' then delete from equip_ca x where x.id = p_id returning to_jsonb(x) into old;
  elsif p_type = 'dotation' then delete from equip_dotations x where x.id = p_id returning to_jsonb(x) into old;
  else return _err('Type inconnu.'); end if;
  if old is null then return _err('Ligne introuvable.'); end if;
  perform _log(a, 'Équipementier : suppression', p_type, old);
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public._equip(public.acces) from public, anon, authenticated;
revoke execute on function public.api_equip_donnees(text), public.api_equip_saison(text, jsonb), public.api_equip_ca(text, jsonb), public.api_equip_dotation(text, jsonb), public.api_equip_suppr(text, text, bigint) from public;
grant execute on function public.api_equip_donnees(text), public.api_equip_saison(text, jsonb), public.api_equip_ca(text, jsonb), public.api_equip_dotation(text, jsonb), public.api_equip_suppr(text, text, bigint) to anon, authenticated;
;
