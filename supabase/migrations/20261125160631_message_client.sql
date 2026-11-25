create or replace function public._err(msg text)
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object('ok', false, 'erreur',
    case when msg like 'PIN incorrect%' then 'Identifiant ou code PIN incorrect (ou trop d''essais : patiente 15 min)'
         when msg = 'Indique l''acheteur.' then 'Indique le client.'
         else msg end)
$$;
revoke execute on function public._err(text) from public, anon, authenticated;
;
