alter table public.ventes add column encaissement_confirme boolean;

create or replace function public.api_vente(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; l jsonb; c catalogue; n int; v_num text; nums text[] := '{}';
        q int; pv numeric; tot numeric := 0; d date; h time(0);
begin
  a := _acces(p_pin);
  if a.id is null then return _err('PIN incorrect'); end if;
  if coalesce(trim(p->>'acheteur'),'') = '' then return _err('Indique le client.'); end if;
  if not exists (select 1 from parametres, jsonb_array_elements_text(valeurs) m where cle = 'modes' and m = p->>'mode') then
    return _err('Mode de règlement non autorisé.'); end if;
  if coalesce((p->>'confirme')::boolean, false) is not true then
    return _err('Coche la confirmation de dépôt / encaissement avant de valider.'); end if;
  if jsonb_typeof(p->'lignes') is distinct from 'array' or jsonb_array_length(p->'lignes') = 0 then return _err('Panier vide.'); end if;
  d := coalesce(nullif(p->>'date','')::date, (now() at time zone 'Europe/Paris')::date);
  h := coalesce(nullif(p->>'heure','')::time(0), (now() at time zone 'Europe/Paris')::time(0));
  perform pg_advisory_xact_lock(4242);
  for l in select jsonb_build_object('ref', x->>'ref', 'qte', sum((x->>'qte')::int)) from jsonb_array_elements(p->'lignes') x group by x->>'ref' loop
    select * into c from catalogue where ref = l->>'ref';
    if c.ref is null or c.statut <> 'Actif' then return _err('Article inconnu ou inactif : ' || coalesce(l->>'ref','?')); end if;
    if (l->>'qte')::int <= 0 then return _err('Quantité invalide.'); end if;
    if (l->>'qte')::int > _stock(c.ref) then return _err('Stock insuffisant pour ' || c.designation || ' (' || _stock(c.ref) || ' dispo).'); end if;
  end loop;
  select coalesce(max(substring(v.num from 2)::int),0) into n from ventes v where v.num ~ '^V[0-9]+$';
  for l in select * from jsonb_array_elements(p->'lignes') loop
    select * into c from catalogue where ref = l->>'ref';
    q := (l->>'qte')::int;
    pv := nullif(l->>'prix','')::numeric;
    if pv is not null and pv < 0 then return _err('Prix invalide.'); end if;
    n := n + 1; v_num := 'V' || lpad(n::text, 4, '0');
    insert into ventes(num, date, heure, acheteur, ref, libelle, quantite, pv_catalogue, pv_applique, montant, pa_unitaire, mode, vendeur, commentaire, encaissement_confirme)
    values (v_num, d, h, trim(p->>'acheteur'), c.ref,
            c.designation || case when c.declinaison <> '' then ' – ' || c.declinaison else '' end,
            q, c.prix_vente, pv, q * coalesce(pv, c.prix_vente), c.prix_achat, p->>'mode', a.nom, coalesce(trim(p->>'commentaire'),''), true);
    nums := nums || v_num; tot := tot + q * coalesce(pv, c.prix_vente);
  end loop;
  return jsonb_build_object('ok', true, 'nums', to_jsonb(nums), 'total', tot);
end $$;
revoke execute on function public.api_vente(text, jsonb) from public;
grant execute on function public.api_vente(text, jsonb) to anon, authenticated;
;
