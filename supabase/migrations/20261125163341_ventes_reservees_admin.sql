create or replace function public.api_donnees(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; adm boolean;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('PIN incorrect'); end if;
  adm := a.role = 'admin';
  return jsonb_build_object(
    'ok', true, 'nom', a.nom, 'role', a.role,
    'catalogue', coalesce((select jsonb_agg(
        case when adm then to_jsonb(c) else to_jsonb(c) - 'prix_achat' - 'description' end
        || jsonb_build_object('stock', _stock(c.ref)) order by c.categorie, c.designation, c.declinaison) from catalogue c), '[]'),
    'ventes', case when adm then coalesce((select jsonb_agg(v order by v.date desc, v.num desc) from ventes v), '[]') else '[]' end,
    'entrees', case when adm then coalesce((select jsonb_agg(e order by e.date desc, e.id desc) from entrees e), '[]') else '[]' end,
    'ajustements', case when adm then coalesce((select jsonb_agg(j order by j.date desc, j.id desc) from ajustements j), '[]') else '[]' end,
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres where adm or cle in ('modes')), '{}')
  );
end $$;
revoke execute on function public.api_donnees(text) from public;
grant execute on function public.api_donnees(text) to anon, authenticated;
;
