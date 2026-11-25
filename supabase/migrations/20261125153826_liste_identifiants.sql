create or replace function public.api_identifiants()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('identifiant', identifiant, 'nom', nom) order by (role = 'admin') desc, nom), '[]')
  from acces where actif
$$;
revoke execute on function public.api_identifiants() from public;
grant execute on function public.api_identifiants() to anon, authenticated;
;
