-- Droit « buvette:responsable » : gestion complète de la buvette + vente (en plus des administrateurs)
create or replace function public._b(a public.acces, p_cle text)
returns boolean language sql stable security definer set search_path = public as $$
  select a.id is not null and a.actif and not a.doit_changer_pin
     and (a.role = 'admin'
          or exists (select 1 from droits where acces_id = a.id and secteur = 'buvette:responsable')
          or (p_cle = 'caisse' and exists (select 1 from droits where acces_id = a.id and secteur = 'buvette:caisse')))
$$;
create or replace function public._bresp(a public.acces, p_pin text)
returns boolean language sql stable security definer set search_path = public as $$
  select _b(a, 'responsable')
$$;
-- Compte « Responsable Buvette » (identifiant responsable.buvette) créé directement sur le projet (PIN non versionné).
