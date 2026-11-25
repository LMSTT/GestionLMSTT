alter table public.acces add column identifiant text;
update public.acces set identifiant = case nom when 'Jérôme' then 'jerome' when 'Adeline' then 'adeline' else 'vendeurs' end;
alter table public.acces alter column identifiant set not null;
create unique index acces_identifiant_key on public.acces (lower(identifiant));

-- p_pin reçoit "identifiant" + saut de ligne + "code PIN"
create or replace function public._acces(p_pin text)
returns public.acces language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; nb int; ident text; code text;
begin
  select count(*) into nb from tentatives where not ok and quand > now() - interval '15 minutes';
  if nb >= 15 then return null; end if;
  if position(E'\n' in coalesce(p_pin,'')) > 0 then
    ident := lower(trim(split_part(p_pin, E'\n', 1)));
    code := substr(p_pin, position(E'\n' in p_pin) + 1);
    select * into a from acces where actif and lower(identifiant) = ident and pin_hash = crypt(code, pin_hash);
  end if;
  insert into tentatives(ok) values (a.id is not null);
  delete from tentatives where quand < now() - interval '1 day';
  return a;
end $$;

create or replace function public.api_donnees(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; adm boolean;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('Identifiant ou code PIN incorrect (ou trop d''essais : patiente 15 min)'); end if;
  adm := a.role = 'admin';
  return jsonb_build_object(
    'ok', true, 'nom', a.nom, 'role', a.role,
    'catalogue', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('stock', _stock(c.ref)) order by c.categorie, c.designation, c.declinaison) from catalogue c), '[]'),
    'ventes', case when adm then coalesce((select jsonb_agg(v order by v.date desc, v.num desc) from ventes v), '[]') else '[]' end,
    'entrees', case when adm then coalesce((select jsonb_agg(e order by e.date desc, e.id desc) from entrees e), '[]') else '[]' end,
    'ajustements', case when adm then coalesce((select jsonb_agg(j order by j.date desc, j.id desc) from ajustements j), '[]') else '[]' end,
    'parametres', coalesce((select jsonb_object_agg(cle, valeurs) from parametres), '{}')
  );
end $$;

create or replace function public.api_connexion(p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('Identifiant ou code PIN incorrect (ou trop d''essais : patiente 15 min)'); end if;
  return jsonb_build_object('ok', true, 'nom', a.nom, 'role', a.role);
end $$;

create or replace function public.api_vente(p_pin text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a public.acces; l jsonb; c catalogue; n int; v_num text; nums text[] := '{}';
        q int; pv numeric; tot numeric := 0; d date;
begin
  a := _acces(p_pin);
  if a.id is null then return _err('Identifiant ou code PIN incorrect (ou trop d''essais : patiente 15 min)'); end if;
  if coalesce(trim(p->>'acheteur'),'') = '' then return _err('Indique l''acheteur.'); end if;
  if not exists (select 1 from parametres, jsonb_array_elements_text(valeurs) m where cle = 'modes' and m = p->>'mode') then
    return _err('Mode de règlement non autorisé.'); end if;
  if jsonb_typeof(p->'lignes') is distinct from 'array' or jsonb_array_length(p->'lignes') = 0 then return _err('Panier vide.'); end if;
  d := coalesce(nullif(p->>'date','')::date, current_date);
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
    insert into ventes(num, date, acheteur, ref, libelle, quantite, pv_catalogue, pv_applique, montant, pa_unitaire, mode, vendeur, commentaire)
    values (v_num, d, trim(p->>'acheteur'), c.ref,
            c.designation || case when c.declinaison <> '' then ' – ' || c.declinaison else '' end,
            q, c.prix_vente, pv, q * coalesce(pv, c.prix_vente), c.prix_achat, p->>'mode', a.nom, coalesce(trim(p->>'commentaire'),''));
    nums := nums || v_num; tot := tot + q * coalesce(pv, c.prix_vente);
  end loop;
  return jsonb_build_object('ok', true, 'nums', to_jsonb(nums), 'total', tot);
end $$;

-- message d'erreur harmonisé dans les fonctions admin
create or replace function public._err(msg text)
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object('ok', false, 'erreur', replace(msg, 'PIN incorrect (ou', 'Identifiant ou code PIN incorrect (ou'))
$$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.api_ping(), public.api_connexion(text), public.api_donnees(text),
  public.api_vente(text, jsonb), public.api_annuler_vente(text, text), public.api_entree(text, jsonb),
  public.api_ajustement(text, jsonb), public.api_supprimer_mouvement(text, text, bigint), public.api_article(text, jsonb)
  to anon, authenticated;
;
