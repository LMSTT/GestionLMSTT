-- Un prénom saisi librement à l'encaissement alimente la liste des vendeurs
create or replace function public.bv_trg_vendeur_liste() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if trim(new.vendeur) <> '' and not exists (select 1 from bv_vendeurs where lower(prenom) = lower(trim(new.vendeur))) then
    insert into bv_vendeurs(prenom) values (initcap(trim(new.vendeur)));
  end if;
  return new;
end $$;
drop trigger if exists bv_vendeur_liste on public.bv_ventes;
create trigger bv_vendeur_liste after insert on public.bv_ventes for each row execute function public.bv_trg_vendeur_liste();
revoke execute on function public.bv_trg_vendeur_liste() from public, anon, authenticated;
