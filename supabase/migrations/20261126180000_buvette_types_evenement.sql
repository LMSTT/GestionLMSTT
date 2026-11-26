-- Types d'événement buvette : Pro A, Tournoi, Compétition, Buvette semaine (Stage et Autre retirés)
alter table public.bv_evenements drop constraint if exists bv_evenements_type_check;
update public.bv_evenements set type = 'Buvette semaine' where type in ('Stage','Autre');
alter table public.bv_evenements add constraint bv_evenements_type_check check (type in ('Pro A','Tournoi','Compétition','Buvette semaine'));

create or replace function public.api_bv_ouvrir(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; e bigint; s bigint;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not (_b(a,'caisse') or _b(a,'responsable')) then return _err('droits'); end if;
  if exists (select 1 from bv_sessions where statut = 'ouverte') then return _err('Une caisse est déjà ouverte.'); end if;
  if coalesce(p->>'type','') not in ('Pro A','Tournoi','Compétition','Buvette semaine') then return _err('Type d''événement inconnu.'); end if;
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

