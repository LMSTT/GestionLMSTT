create extension if not exists pgcrypto with schema extensions;

create table public.catalogue (
  ref text primary key,
  ref_principale text not null,
  declinaison text not null default '',
  designation text not null,
  categorie text not null default '',
  description text not null default '',
  fournisseur text not null default '',
  prix_achat numeric(10,2) not null default 0,
  prix_vente numeric(10,2) not null default 0,
  seuil int not null default 0,
  stock_initial int not null default 0,
  statut text not null default 'Actif' check (statut in ('Actif','Inactif')),
  maj_le timestamptz not null default now()
);

create table public.ventes (
  num text primary key,
  date date not null,
  acheteur text not null,
  ref text not null references public.catalogue(ref) on update cascade,
  libelle text not null,
  quantite int not null check (quantite > 0),
  pv_catalogue numeric(10,2) not null,
  pv_applique numeric(10,2),
  montant numeric(10,2) not null,
  pa_unitaire numeric(10,2) not null default 0,
  mode text not null,
  vendeur text not null,
  commentaire text not null default '',
  cree_le timestamptz not null default now()
);
create index on public.ventes(date);
create index on public.ventes(ref);

create table public.entrees (
  id bigint generated always as identity primary key,
  date date not null,
  num_commande text not null default '',
  fournisseur text not null default '',
  ref text not null references public.catalogue(ref) on update cascade,
  quantite int not null check (quantite > 0),
  prix_achat numeric(10,2) not null default 0,
  commentaire text not null default '',
  saisi_par text not null default '',
  cree_le timestamptz not null default now()
);
create index on public.entrees(ref);

create table public.ajustements (
  id bigint generated always as identity primary key,
  date date not null,
  ref text not null references public.catalogue(ref) on update cascade,
  quantite int not null check (quantite <> 0),
  motif text not null,
  commentaire text not null default '',
  saisi_par text not null default '',
  cree_le timestamptz not null default now()
);
create index on public.ajustements(ref);

create table public.parametres (
  cle text primary key,
  valeurs jsonb not null
);

create table public.acces (
  id bigint generated always as identity primary key,
  nom text not null,
  role text not null check (role in ('vendeur','admin')),
  pin_hash text not null,
  actif boolean not null default true
);

create table public.tentatives (
  id bigint generated always as identity primary key,
  quand timestamptz not null default now(),
  ok boolean not null
);
create index on public.tentatives(quand);

-- Aucune lecture/écriture directe : tout passe par les fonctions api_*
alter table public.catalogue enable row level security;
alter table public.ventes enable row level security;
alter table public.entrees enable row level security;
alter table public.ajustements enable row level security;
alter table public.parametres enable row level security;
alter table public.acces enable row level security;
alter table public.tentatives enable row level security;
revoke all on public.catalogue, public.ventes, public.entrees, public.ajustements, public.parametres, public.acces, public.tentatives from anon, authenticated;

;
