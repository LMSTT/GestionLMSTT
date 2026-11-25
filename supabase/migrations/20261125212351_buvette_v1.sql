-- =====================================================================
-- Buvette V1 : caisse, vendeurs (prénom), sessions de caisse, clôture
-- Tables bv_* séparées de l'existant. Accès uniquement via fonctions api_bv_*.
-- =====================================================================

-- ---------- Tables ----------
create table public.bv_categories (
  id bigint generated always as identity primary key,
  nom text not null,
  ordre int not null default 0,
  actif boolean not null default true
);

create table public.bv_produits (
  id bigint generated always as identity primary key,
  categorie_id bigint references public.bv_categories(id) on delete set null,
  nom text not null,
  prix_vente numeric(10,2) not null check (prix_vente >= 0),
  prix_achat numeric(10,2) not null default 0 check (prix_achat >= 0),
  stock int not null default 0,
  seuil int not null default 0,
  actif boolean not null default true,
  ordre int not null default 0,
  cree_le timestamptz not null default now(),
  maj_le timestamptz not null default now()
);

create table public.bv_vendeurs (
  id bigint generated always as identity primary key,
  prenom text not null,
  actif boolean not null default true,
  cree_le timestamptz not null default now()
);

create table public.bv_evenements (
  id bigint generated always as identity primary key,
  type text not null check (type in ('Pro A','Tournoi','Compétition','Stage','Autre')),
  date date not null,
  libelle text not null default '',
  adversaire text not null default '',
  saison text generated always as (
    case when extract(month from date) >= 8
         then extract(year from date)::int::text || '-' || (extract(year from date)::int + 1)::text
         else (extract(year from date)::int - 1)::text || '-' || extract(year from date)::int::text end) stored,
  cree_par text not null default '',
  cree_le timestamptz not null default now()
);

create table public.bv_sessions (
  id bigint generated always as identity primary key,
  evenement_id bigint not null references public.bv_evenements(id),
  statut text not null default 'ouverte' check (statut in ('ouverte','cloturee')),
  fond numeric(10,2) not null default 0,
  ouverte_par text not null default '',
  ouverte_le timestamptz not null default now(),
  cloturee_par text,
  cloturee_le timestamptz,
  especes_attendues numeric(10,2),
  especes_comptees numeric(10,2),
  ecart_especes numeric(10,2),
  cb_appli numeric(10,2),
  cb_tpe numeric(10,2),
  ecart_cb numeric(10,2),
  commentaire text not null default ''
);
create unique index bv_une_session_ouverte on public.bv_sessions ((statut)) where statut = 'ouverte';

create table public.bv_ventes (
  id uuid primary key,                       -- généré sur la tablette (hors-ligne sans doublon)
  session_id bigint not null references public.bv_sessions(id),
  vendeur text not null,
  vendue_le timestamptz not null,            -- heure de la tablette
  recue_le timestamptz not null default now(),
  mode text not null check (mode in ('especes','cb','offert')),
  total numeric(10,2) not null default 0,    -- 0 pour un offert
  valeur_achat numeric(10,2) not null default 0,
  recu numeric(10,2),
  rendu numeric(10,2),
  beneficiaire_type text check (beneficiaire_type in ('Staff','Joueur')),
  beneficiaire_nom text not null default '',
  poste text not null default '',
  annulee boolean not null default false,
  annulee_par text,
  annulee_le timestamptz,
  motif_annulation text,
  constraint bv_offert_beneficiaire check (mode <> 'offert' or beneficiaire_type is not null)
);
create index on public.bv_ventes(session_id);
create index on public.bv_ventes(vendue_le);

create table public.bv_lignes (
  id bigint generated always as identity primary key,
  vente_id uuid not null references public.bv_ventes(id),
  produit_id bigint not null references public.bv_produits(id),
  nom text not null,
  qte int not null check (qte > 0),
  prix_vente numeric(10,2) not null,
  prix_achat numeric(10,2) not null
);
create index on public.bv_lignes(vente_id);
create index on public.bv_lignes(produit_id);

create table public.bv_mouvements (
  id bigint generated always as identity primary key,
  produit_id bigint not null references public.bv_produits(id),
  type text not null check (type in ('stock initial','livraison','achat','inventaire','perte','casse','correction')),
  qte int not null,
  cout_unitaire numeric(10,2),
  motif text not null default '',
  par text not null default '',
  le timestamptz not null default now()
);
create index on public.bv_mouvements(produit_id);

alter table public.bv_categories enable row level security;
alter table public.bv_produits enable row level security;
alter table public.bv_vendeurs enable row level security;
alter table public.bv_evenements enable row level security;
alter table public.bv_sessions enable row level security;
alter table public.bv_ventes enable row level security;
alter table public.bv_lignes enable row level security;
alter table public.bv_mouvements enable row level security;
revoke all on public.bv_categories, public.bv_produits, public.bv_vendeurs, public.bv_evenements,
  public.bv_sessions, public.bv_ventes, public.bv_lignes, public.bv_mouvements from anon, authenticated;

-- ---------- Triggers de stock ----------
create or replace function public.bv_trg_ligne_stock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update bv_produits set stock = stock - new.qte, maj_le = now() where id = new.produit_id;
  return new;
end $$;
create trigger bv_ligne_stock after insert on public.bv_lignes
  for each row execute function public.bv_trg_ligne_stock();

create or replace function public.bv_trg_annulation_stock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.annulee and not old.annulee then
    update bv_produits p set stock = p.stock + l.qte, maj_le = now()
      from (select produit_id, sum(qte) qte from bv_lignes where vente_id = new.id group by produit_id) l
     where p.id = l.produit_id;
  end if;
  return new;
end $$;
create trigger bv_annulation_stock after update of annulee on public.bv_ventes
  for each row execute function public.bv_trg_annulation_stock();

create or replace function public.bv_trg_mouvement_stock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update bv_produits set stock = stock + new.qte, maj_le = now() where id = new.produit_id;
  return new;
end $$;
create trigger bv_mouvement_stock after insert on public.bv_mouvements
  for each row execute function public.bv_trg_mouvement_stock();

-- ---------- Droits ----------
-- buvette:caisse (vendre, ouvrir/clôturer la caisse) ; buvette:responsable (tout le reste).
-- Mode responsable sur le compte commun : code responsable -> déverrouillage 15 min de la session.
alter table public.sessions add column if not exists resp_jusqu timestamptz;

create or replace function public._b(a public.acces, p_cle text)
returns boolean language sql stable security definer set search_path = public as $$
  select a.id is not null and a.actif and not a.doit_changer_pin
     and (a.role = 'admin' or exists (select 1 from droits where acces_id = a.id and secteur = 'buvette:' || p_cle))
$$;

-- responsable : droit permanent OU mode responsable actif sur la session courante
create or replace function public._bresp(a public.acces, p_pin text)
returns boolean language sql stable security definer set search_path = public as $$
  select _b(a, 'responsable') or (_b(a, 'caisse') and exists (
    select 1 from sessions s where s.token = substr(p_pin, 3)::uuid and s.resp_jusqu > now()))
$$;

create or replace function public._droits(a public.acces)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'caisse', _a(a,'caisse'), 'stocks', _a(a,'stocks'), 'ventes', _a(a,'ventes'), 'ventes_annuler', _a(a,'ventes_annuler'),
    'entrees', _a(a,'entrees'), 'bilan', _a(a,'bilan'), 'catalogue', _a(a,'catalogue'),
    'eq_bord', _e(a,'bord'), 'eq_ca', _e(a,'ca'), 'eq_dot', _e(a,'dot'), 'equipementier', _equip(a),
    'bv_caisse', _b(a,'caisse'), 'bv_resp', _b(a,'responsable'), 'buvette', _b(a,'caisse') or _b(a,'responsable'),
    'administration', a.role = 'admin' and a.actif and not a.doit_changer_pin)
$$;

-- ---------- Lecture ----------
create or replace function public._bv_session_ouverte()
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(s) || jsonb_build_object('evenement', to_jsonb(e),
    'totaux', (select jsonb_build_object(
        'especes', coalesce(sum(total) filter (where mode = 'especes'),0),
        'cb', coalesce(sum(total) filter (where mode = 'cb'),0),
        'offert_nb', count(*) filter (where mode = 'offert'),
        'offert_valeur', coalesce(sum(valeur_achat) filter (where mode = 'offert'),0),
        'nb', count(*))
      from bv_ventes v where v.session_id = s.id and not v.annulee))
  from bv_sessions s join bv_evenements e on e.id = s.evenement_id
  where s.statut = 'ouverte' limit 1
$$;

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
    'produits', coalesce((select jsonb_agg(case when resp then to_jsonb(p) else to_jsonb(p) - 'prix_achat' end order by p.ordre, p.nom)
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

-- ---------- Mode responsable (compte commun) ----------
create or replace function public.api_bv_resp(p_pin text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; h text;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _b(a,'caisse') then return _err('droits'); end if;
  if _b(a,'responsable') then return jsonb_build_object('ok', true); end if;
  select hash into h from secrets where cle = 'buvette_responsable';
  if h is null then return _err('Aucun code responsable défini (Administration › Paramètres).'); end if;
  if h <> crypt(coalesce(p_code,''), h) then
    update acces set echecs = echecs + 1 where id = a.id returning * into a;
    perform _log(a, 'Buvette : échec code responsable');
    if a.echecs >= 5 then
      update acces set echecs = 0 where id = a.id;
      update sessions set resp_jusqu = null where token = substr(p_pin,3)::uuid;
      return _err('5 codes faux : réessaie plus tard.');
    end if;
    return _err('Code responsable incorrect.');
  end if;
  update acces set echecs = 0 where id = a.id;
  update sessions set resp_jusqu = now() + interval '15 minutes' where token = substr(p_pin,3)::uuid;
  perform _log(a, 'Buvette : mode responsable ouvert');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_bv_resp_fin(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  update sessions set resp_jusqu = null where token = substr(p_pin,3)::uuid;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_admin_bv_code(p_pin text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  if coalesce(p_code,'') !~ '^[0-9]{4,8}$' then return _err('Code responsable : 4 à 8 chiffres.'); end if;
  insert into secrets(cle, hash) values ('buvette_responsable', crypt(p_code, gen_salt('bf')))
  on conflict (cle) do update set hash = excluded.hash, maj_le = now();
  perform _log(a, 'Buvette : code responsable modifié');
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Sessions de caisse ----------
create or replace function public.api_bv_ouvrir(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; e bigint; s bigint;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not (_b(a,'caisse') or _b(a,'responsable')) then return _err('droits'); end if;
  if exists (select 1 from bv_sessions where statut = 'ouverte') then return _err('Une caisse est déjà ouverte.'); end if;
  if coalesce(p->>'type','') not in ('Pro A','Tournoi','Compétition','Stage','Autre') then return _err('Type d''événement inconnu.'); end if;
  if coalesce(nullif(p->>'fond','')::numeric, -1) < 0 then return _err('Indique le fond de caisse.'); end if;
  if coalesce(trim(p->>'vendeur'),'') = '' then return _err('Indique ton prénom.'); end if;
  insert into bv_evenements(type, date, libelle, adversaire, cree_par)
  values (p->>'type', coalesce(nullif(p->>'date','')::date, (now() at time zone 'Europe/Paris')::date),
          trim(coalesce(p->>'libelle','')), trim(coalesce(p->>'adversaire','')), trim(p->>'vendeur'))
  returning id into e;
  insert into bv_sessions(evenement_id, fond, ouverte_par) values (e, (p->>'fond')::numeric, trim(p->>'vendeur')) returning id into s;
  perform _log(a, 'Buvette : ouverture de caisse', p->>'type', jsonb_build_object('session', s, 'fond', p->>'fond', 'vendeur', p->>'vendeur', 'adversaire', p->>'adversaire'));
  return jsonb_build_object('ok', true, 'session', s);
end $$;

-- Synchronisation des ventes (idempotente : une vente déjà reçue est ignorée)
create or replace function public.api_bv_ventes(p_pin text, p_ventes jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; v jsonb; l jsonb; pr bv_produits; tot numeric; va numeric; ok text[] := '{}'; ko jsonb := '[]'; vid uuid; sid bigint; m text;
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
      if m not in ('especes','cb','offert') then raise exception 'Mode inconnu'; end if;
      if coalesce(trim(v->>'vendeur'),'') = '' then raise exception 'Vendeur manquant'; end if;
      if m = 'offert' and coalesce(v->>'beneficiaire_type','') not in ('Staff','Joueur') then raise exception 'Bénéficiaire manquant'; end if;
      if jsonb_typeof(v->'lignes') <> 'array' or jsonb_array_length(v->'lignes') = 0 then raise exception 'Panier vide'; end if;
      tot := 0; va := 0;
      for l in select * from jsonb_array_elements(v->'lignes') loop
        select * into pr from bv_produits where id = (l->>'produit_id')::bigint;
        if pr.id is null then raise exception 'Produit inconnu'; end if;
        if (l->>'qte')::int <= 0 then raise exception 'Quantité invalide'; end if;
        tot := tot + (l->>'qte')::int * coalesce(nullif(l->>'prix','')::numeric, pr.prix_vente);
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
        values (vid, pr.id, pr.nom, (l->>'qte')::int, coalesce(nullif(l->>'prix','')::numeric, pr.prix_vente), pr.prix_achat);
      end loop;
      ok := ok || vid::text;
    exception when others then
      ko := ko || jsonb_build_object('id', v->>'id', 'erreur', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('ok', true, 'acceptees', to_jsonb(ok), 'refusees', ko);
end $$;

create or replace function public.api_bv_annuler(p_pin text, p_id uuid, p_motif text, p_vendeur text default '')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; v bv_ventes; qui text;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _bresp(a, p_pin) then return _err('droits'); end if;
  if coalesce(trim(p_motif),'') = '' then return _err('Indique le motif.'); end if;
  qui := case when _b(a,'responsable') then a.nom else 'Responsable (' || coalesce(nullif(trim(p_vendeur),''), a.nom) || ')' end;
  update bv_ventes set annulee = true, annulee_par = qui, annulee_le = now(), motif_annulation = trim(p_motif)
   where id = p_id and not annulee returning * into v;
  if v.id is null then return _err('Vente introuvable ou déjà annulée.'); end if;
  perform _log(a, 'Buvette : annulation', v.id::text, jsonb_build_object('total', v.total, 'mode', v.mode, 'vendeur', v.vendeur, 'motif', trim(p_motif), 'par', qui));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public._bv_recap(p_session bigint)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(s) || jsonb_build_object('evenement', to_jsonb(e),
    'par_mode', (select jsonb_build_object(
        'especes', coalesce(sum(total) filter (where mode = 'especes'),0), 'nb_especes', count(*) filter (where mode = 'especes'),
        'cb', coalesce(sum(total) filter (where mode = 'cb'),0), 'nb_cb', count(*) filter (where mode = 'cb'),
        'offert_nb', count(*) filter (where mode = 'offert'), 'offert_valeur', coalesce(sum(valeur_achat) filter (where mode = 'offert'),0),
        'offert_staff', count(*) filter (where mode = 'offert' and beneficiaire_type = 'Staff'),
        'offert_joueur', count(*) filter (where mode = 'offert' and beneficiaire_type = 'Joueur'),
        'nb', count(*) filter (where mode <> 'offert'),
        'annulees', (select count(*) from bv_ventes where session_id = s.id and annulee))
      from bv_ventes where session_id = s.id and not annulee),
    'produits', coalesce((select jsonb_agg(x order by x.qte desc) from (
        select l.nom, sum(l.qte) qte, sum(l.qte * l.prix_vente) filter (where v.mode <> 'offert') montant
        from bv_lignes l join bv_ventes v on v.id = l.vente_id where v.session_id = s.id and not v.annulee group by l.nom) x), '[]'),
    'vendeurs', coalesce((select jsonb_agg(x order by x.montant desc) from (
        select vendeur, count(*) nb, sum(total) montant from bv_ventes where session_id = s.id and not annulee group by vendeur) x), '[]'))
  from bv_sessions s join bv_evenements e on e.id = s.evenement_id where s.id = p_session
$$;

create or replace function public.api_bv_cloturer(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; s bv_sessions; esp numeric; cb numeric;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not (_b(a,'caisse') or _b(a,'responsable')) then return _err('droits'); end if;
  select * into s from bv_sessions where id = (p->>'session_id')::bigint;
  if s.id is null or s.statut <> 'ouverte' then return _err('Caisse introuvable ou déjà clôturée.'); end if;
  if nullif(p->>'especes_comptees','') is null or nullif(p->>'cb_tpe','') is null then return _err('Indique le total des espèces et le total du ticket TPE.'); end if;
  if coalesce(trim(p->>'vendeur'),'') = '' then return _err('Indique ton prénom.'); end if;
  select coalesce(sum(total) filter (where mode = 'especes'),0), coalesce(sum(total) filter (where mode = 'cb'),0)
    into esp, cb from bv_ventes where session_id = s.id and not annulee;
  update bv_sessions set statut = 'cloturee', cloturee_par = trim(p->>'vendeur'), cloturee_le = now(),
    especes_attendues = fond + esp, especes_comptees = (p->>'especes_comptees')::numeric,
    ecart_especes = (p->>'especes_comptees')::numeric - (fond + esp),
    cb_appli = cb, cb_tpe = (p->>'cb_tpe')::numeric, ecart_cb = (p->>'cb_tpe')::numeric - cb,
    commentaire = coalesce(p->>'commentaire','')
   where id = s.id;
  perform _log(a, 'Buvette : clôture de caisse', s.id::text, jsonb_build_object('vendeur', p->>'vendeur',
    'ecart_especes', (p->>'especes_comptees')::numeric - (s.fond + esp), 'ecart_cb', (p->>'cb_tpe')::numeric - cb));
  return jsonb_build_object('ok', true, 'recap', _bv_recap(s.id));
end $$;

create or replace function public.api_bv_recap(p_pin text, p_session bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _bresp(a, p_pin) then return _err('droits'); end if;
  return jsonb_build_object('ok', true, 'recap', _bv_recap(p_session));
end $$;

-- ---------- Gestion (responsables) ----------
create or replace function public.api_bv_produit(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; i bigint; st int;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _bresp(a, p_pin) then return _err('droits'); end if;
  if coalesce(trim(p->>'nom'),'') = '' then return _err('Nom du produit requis.'); end if;
  if coalesce(nullif(p->>'prix_vente','')::numeric, -1) < 0 then return _err('Prix de vente requis.'); end if;
  if nullif(p->>'id','') is null then
    insert into bv_produits(categorie_id, nom, prix_vente, prix_achat, seuil, actif, ordre)
    values (nullif(p->>'categorie_id','')::bigint, trim(p->>'nom'), (p->>'prix_vente')::numeric, coalesce(nullif(p->>'prix_achat','')::numeric,0),
            coalesce(nullif(p->>'seuil','')::int,0), coalesce((p->>'actif')::boolean, true), coalesce(nullif(p->>'ordre','')::int,0))
    returning id into i;
    st := coalesce(nullif(p->>'stock','')::int, 0);
    if st <> 0 then insert into bv_mouvements(produit_id, type, qte, motif, par) values (i, 'stock initial', st, '', a.nom); end if;
    perform _log(a, 'Buvette : création de produit', trim(p->>'nom'), p);
  else
    i := (p->>'id')::bigint;
    update bv_produits set categorie_id = nullif(p->>'categorie_id','')::bigint, nom = trim(p->>'nom'), prix_vente = (p->>'prix_vente')::numeric,
      prix_achat = coalesce(nullif(p->>'prix_achat','')::numeric, prix_achat), seuil = coalesce(nullif(p->>'seuil','')::int, seuil),
      actif = coalesce((p->>'actif')::boolean, actif), ordre = coalesce(nullif(p->>'ordre','')::int, ordre), maj_le = now()
     where id = i;
    if not found then return _err('Produit introuvable.'); end if;
    perform _log(a, 'Buvette : modification de produit', trim(p->>'nom'), p);
  end if;
  return jsonb_build_object('ok', true, 'id', i);
end $$;

create or replace function public.api_bv_produit_suppr(p_pin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; n text;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _bresp(a, p_pin) then return _err('droits'); end if;
  select nom into n from bv_produits where id = p_id;
  if n is null then return _err('Produit introuvable.'); end if;
  if exists (select 1 from bv_lignes where produit_id = p_id) then
    update bv_produits set actif = false, maj_le = now() where id = p_id;
    perform _log(a, 'Buvette : produit désactivé', n);
    return jsonb_build_object('ok', true, 'desactive', true);
  end if;
  delete from bv_mouvements where produit_id = p_id;
  delete from bv_produits where id = p_id;
  perform _log(a, 'Buvette : produit supprimé', n);
  return jsonb_build_object('ok', true, 'desactive', false);
end $$;

create or replace function public.api_bv_categorie(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _bresp(a, p_pin) then return _err('droits'); end if;
  if coalesce(trim(p->>'nom'),'') = '' then return _err('Nom de catégorie requis.'); end if;
  if nullif(p->>'id','') is null then
    insert into bv_categories(nom, ordre) values (trim(p->>'nom'), coalesce(nullif(p->>'ordre','')::int, 0));
  else
    update bv_categories set nom = trim(p->>'nom'), ordre = coalesce(nullif(p->>'ordre','')::int, ordre), actif = coalesce((p->>'actif')::boolean, actif)
     where id = (p->>'id')::bigint;
  end if;
  perform _log(a, 'Buvette : catégorie', trim(p->>'nom'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_bv_vendeur(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _bresp(a, p_pin) then return _err('droits'); end if;
  if coalesce(trim(p->>'prenom'),'') = '' then return _err('Prénom requis.'); end if;
  if nullif(p->>'id','') is null then
    if exists (select 1 from bv_vendeurs where lower(prenom) = lower(trim(p->>'prenom')) and actif) then return _err('Ce prénom existe déjà.'); end if;
    insert into bv_vendeurs(prenom) values (trim(p->>'prenom'));
  else
    update bv_vendeurs set prenom = trim(p->>'prenom'), actif = coalesce((p->>'actif')::boolean, actif) where id = (p->>'id')::bigint;
  end if;
  perform _log(a, 'Buvette : vendeur', trim(p->>'prenom'), jsonb_build_object('actif', p->>'actif'));
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Admin : accès Buvette dans la gestion des utilisateurs ----------
create or replace function public.api_admin_donnees(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _est_admin(a) then return _err('droits'); end if;
  return jsonb_build_object('ok', true, 'moi', a.id, 'reglages', _reglages(),
    'bv_code_defini', exists (select 1 from secrets where cle = 'buvette_responsable'),
    'sessions', _liste_sessions(null, substr(p_pin,3)::uuid),
    'utilisateurs', coalesce((select jsonb_agg(jsonb_build_object(
        'id', u.id, 'nom', u.nom, 'identifiant', u.identifiant, 'role', u.role, 'actif', u.actif,
        'doit_changer_pin', u.doit_changer_pin, 'bloque_jusqu', case when u.bloque_jusqu > now() then u.bloque_jusqu end,
        'derniere_connexion', u.derniere_connexion, 'cree_le', u.cree_le,
        'sessions', (select count(*) from sessions s where s.acces_id = u.id and s.expire_le > now() and (s.inactivite_max is null or s.derniere_activite > now() - s.inactivite_max)),
        'acces', coalesce((select jsonb_agg(case when secteur like 'equipementier:%' then 'eq_' || substr(secteur, 15)
                                                 when secteur like 'buvette:%' then 'bv_' || case substr(secteur, 9) when 'responsable' then 'resp' else substr(secteur, 9) end
                                                 else substr(secteur, 10) end order by secteur)
                           from droits d where d.acces_id = u.id and (secteur like 'boutique:%' or secteur like 'equipementier:%' or secteur like 'buvette:%')), '[]'))
      order by u.role, u.nom) from acces u), '[]'),
    'journal', coalesce((select jsonb_agg(to_jsonb(j) order by j.quand desc) from (select * from journal order by quand desc limit 500) j), '[]'),
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres where cle <> 'session'), '{}'));
end $$;

create or replace function public.api_admin_utilisateur(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; u public.acces; ident text; k text; nouveau boolean; ancien text;
        cles text[] := array['caisse','stocks','ventes','ventes_annuler','entrees','bilan','catalogue','eq_bord','eq_ca','eq_dot','bv_caisse','bv_resp'];
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
    delete from droits where acces_id = u.id and (secteur like 'boutique:%' or secteur like 'equipementier%' or secteur like 'buvette:%');
    for k in select jsonb_array_elements_text(p->'acces') loop
      if not k = any(cles) then return _err('Accès inconnu : ' || k); end if;
      insert into droits(acces_id, secteur, niveau)
      values (u.id, case when k like 'eq\_%' then 'equipementier:' || substr(k, 4)
                         when k = 'bv_caisse' then 'buvette:caisse' when k = 'bv_resp' then 'buvette:responsable'
                         else 'boutique:' || k end, 'oui') on conflict do nothing;
    end loop;
  end if;
  perform _log(a, case when nouveau then 'Création d''utilisateur' else 'Modification d''utilisateur' end, u.identifiant,
               jsonb_build_object('nom', u.nom, 'role', u.role, 'actif', u.actif, 'acces', p->'acces')
               || case when ancien is not null and ancien <> u.identifiant then jsonb_build_object('ancien_identifiant', ancien) else '{}' end);
  return jsonb_build_object('ok', true, 'id', u.id);
end $$;

-- ---------- Exécution ----------
revoke execute on function public.bv_trg_ligne_stock(), public.bv_trg_annulation_stock(), public.bv_trg_mouvement_stock(),
  public._b(public.acces, text), public._bresp(public.acces, text), public._bv_session_ouverte(), public._bv_recap(bigint),
  public._droits(public.acces) from public, anon, authenticated;
grant execute on function
  public.api_bv_donnees(text), public.api_bv_resp(text, text), public.api_bv_resp_fin(text), public.api_admin_bv_code(text, text),
  public.api_bv_ouvrir(text, jsonb), public.api_bv_ventes(text, jsonb), public.api_bv_annuler(text, uuid, text, text),
  public.api_bv_cloturer(text, jsonb), public.api_bv_recap(text, bigint), public.api_bv_produit(text, jsonb),
  public.api_bv_produit_suppr(text, bigint), public.api_bv_categorie(text, jsonb), public.api_bv_vendeur(text, jsonb),
  public.api_admin_donnees(text), public.api_admin_utilisateur(text, jsonb)
to anon, authenticated;
