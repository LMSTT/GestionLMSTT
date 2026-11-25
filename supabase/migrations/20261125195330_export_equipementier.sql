create or replace function public._export()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('exporte_le', now(),
    'catalogue', coalesce((select jsonb_agg(c) from catalogue c), '[]'),
    'ventes', coalesce((select jsonb_agg(v order by v.num) from ventes v), '[]'),
    'entrees', coalesce((select jsonb_agg(e order by e.id) from entrees e), '[]'),
    'ajustements', coalesce((select jsonb_agg(j order by j.id) from ajustements j), '[]'),
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres), '{}'),
    'utilisateurs', coalesce((select jsonb_agg(jsonb_build_object('nom', nom, 'identifiant', identifiant, 'role', role, 'actif', actif)) from acces), '[]'),
    'droits', coalesce((select jsonb_agg(jsonb_build_object('identifiant', ac.identifiant, 'acces', d.secteur)) from droits d join acces ac on ac.id = d.acces_id), '[]'),
    'equipementier', jsonb_build_object(
      'saisons', coalesce((select jsonb_agg(s) from equip_saisons s), '[]'),
      'ca', coalesce((select jsonb_agg(c order by c.id) from equip_ca c), '[]'),
      'dotations', coalesce((select jsonb_agg(d order by d.id) from equip_dotations d), '[]')),
    'journal', coalesce((select jsonb_agg(j order by j.id) from journal j), '[]'))
$$;
revoke execute on function public._export() from public, anon, authenticated;
;
