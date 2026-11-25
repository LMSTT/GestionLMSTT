create or replace function public.api_changer_pin(p_pin text, p_nouveau text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('Code actuel incorrect.'); end if;
  if coalesce(p_nouveau,'') !~ '^[0-9]{4}$' then return _err('Le nouveau code doit faire exactement 4 chiffres.'); end if;
  update acces set pin_hash = crypt(p_nouveau, gen_salt('bf')) where id = a.id;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.api_changer_pin(text, text) from public;
grant execute on function public.api_changer_pin(text, text) to anon, authenticated;
;
