-- Buvette semaine : caisse permanente, sans ouverture ni clôture (fond de caisse au club)
alter table public.bv_sessions add column if not exists permanente boolean not null default false;
drop index if exists public.bv_une_session_ouverte;
create unique index bv_une_session_ouverte on public.bv_sessions ((statut)) where statut = 'ouverte' and not permanente;
create unique index if not exists bv_une_permanente on public.bv_sessions ((permanente)) where permanente;

do $$ declare e bigint; begin
  if not exists (select 1 from public.bv_sessions where permanente) then
    insert into public.bv_evenements(type, date, libelle, cree_par) values ('Buvette semaine', (now() at time zone 'Europe/Paris')::date, 'Buvette semaine', 'système') returning id into e;
    insert into public.bv_sessions(evenement_id, fond, ouverte_par, permanente) values (e, 0, 'système', true);
  end if;
end $$;

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
  where s.statut = 'ouverte' order by s.permanente, s.ouverte_le desc limit 1
$$;

create or replace function public.api_bv_ouvrir(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; e bigint; s bigint;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not (_b(a,'caisse') or _b(a,'responsable')) then return _err('droits'); end if;
  if exists (select 1 from bv_sessions where statut = 'ouverte' and not permanente) then return _err('Une caisse est déjà ouverte.'); end if;
  if coalesce(p->>'type','') not in ('Pro A','Tournoi','Compétition') then return _err('Type d''événement inconnu.'); end if;
  if coalesce(nullif(p->>'fond','')::numeric, -1) < 0 then return _err('Indique le fond de caisse.'); end if;
  if coalesce(trim(p->>'vendeur'),'') = '' then return _err('Indique ton prénom.'); end if;
  insert into bv_evenements(type, date, libelle, adversaire, cree_par)
  values (p->>'type', coalesce(nullif(p->>'date','')::date, (now() at time zone 'Europe/Paris')::date),
          trim(coalesce(p->>'libelle','')), trim(coalesce(p->>'adversaire','')), trim(p->>'vendeur'))
  returning id into e;
  insert into bv_sessions(evenement_id, fond, ouverte_par) values (e, (p->>'fond')::numeric, trim(p->>'vendeur')) returning id into s;
  perform _log(a, 'Buvette : ouverture de caisse', p->>'type', jsonb_build_object('session', s, 'fond', p->>'fond', 'vendeur', p->>'vendeur', 'description', p->>'libelle'));
  return jsonb_build_object('ok', true, 'session', s);
end $$;

create or replace function public.bv_trg_pas_cloture_permanente() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.permanente and new.statut <> 'ouverte' then raise exception 'La buvette semaine ne se clôture pas.'; end if;
  return new;
end $$;
drop trigger if exists bv_pas_cloture_permanente on public.bv_sessions;
create trigger bv_pas_cloture_permanente before update on public.bv_sessions
  for each row execute function public.bv_trg_pas_cloture_permanente();
revoke execute on function public.bv_trg_pas_cloture_permanente(), public._bv_session_ouverte() from public, anon, authenticated;
