create or replace function public.api_compte(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; deb date; today date := (now() at time zone 'Europe/Paris')::date;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('PIN incorrect'); end if;
  deb := make_date(extract(year from today)::int - case when extract(month from today) >= 8 then 0 else 1 end, 8, 1);
  return jsonb_build_object('ok', true, 'nom', a.nom, 'identifiant', a.identifiant, 'role', a.role,
    'saison', extract(year from deb)::int || '-' || (extract(year from deb)::int + 1),
    'nb_ventes', (select count(*) from ventes where vendeur = a.nom and date >= deb),
    'montant', (select coalesce(sum(montant),0) from ventes where vendeur = a.nom and date >= deb),
    'nb_jour', (select count(*) from ventes where vendeur = a.nom and date = today),
    'montant_jour', (select coalesce(sum(montant),0) from ventes where vendeur = a.nom and date = today),
    'derniere', (select max(date::text || ' ' || coalesce(to_char(heure,'HH24:MI'),'')) from ventes where vendeur = a.nom));
end $$;

create or replace function public.api_changer_pin(p_pin text, p_nouveau text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('Code actuel incorrect.'); end if;
  if length(coalesce(p_nouveau,'')) < 4 then return _err('Le nouveau code doit faire au moins 4 caractères.'); end if;
  if position(E'\n' in p_nouveau) > 0 then return _err('Caractère non autorisé.'); end if;
  update acces set pin_hash = crypt(p_nouveau, gen_salt('bf')) where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public.api_compte(text), public.api_changer_pin(text, text) from public;
grant execute on function public.api_compte(text), public.api_changer_pin(text, text) to anon, authenticated;
;
