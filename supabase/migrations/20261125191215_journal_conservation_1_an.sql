create or replace function public._log(a public.acces, p_action text, p_cible text default '', p_details jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into journal(acces_id, nom, action, cible, details) values (a.id, coalesce(a.nom,''), p_action, coalesce(p_cible,''), coalesce(p_details,'{}'));
  delete from journal where quand < now() - interval '1 year';
$$;
revoke execute on function public._log(public.acces, text, text, jsonb) from public, anon, authenticated;
;
