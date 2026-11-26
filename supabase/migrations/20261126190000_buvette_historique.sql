-- Historique des ventes buvette consultable par les vendeurs (lecture seule)
create or replace function public.api_bv_historique(p_pin text, p_jours int default 7)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; j int := least(greatest(coalesce(p_jours,7),1),62);
begin
  a := _acces(p_pin);
  if a.id is null then return _err('session'); end if;
  if not _b(a,'caisse') then return _err('droits'); end if;
  return jsonb_build_object('ok', true, 'ventes', coalesce((select jsonb_agg(x order by x.vendue_le desc) from (
    select v.id, v.vendue_le, v.vendeur, v.mode, v.total, v.beneficiaire_type, v.beneficiaire_nom, v.annulee,
           e.type evenement, e.libelle,
           (select jsonb_agg(jsonb_build_object('nom', l.nom, 'qte', l.qte, 'prix', l.prix_vente)) from bv_lignes l where l.vente_id = v.id) lignes
      from bv_ventes v join bv_sessions s on s.id = v.session_id join bv_evenements e on e.id = s.evenement_id
     where v.vendue_le > now() - make_interval(days => j)
     order by v.vendue_le desc limit 500) x), '[]'));
end $$;
grant execute on function public.api_bv_historique(text, int) to anon, authenticated;
