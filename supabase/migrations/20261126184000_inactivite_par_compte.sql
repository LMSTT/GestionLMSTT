-- Durée d'inactivité propre à un compte (Vendeur Buvette : 10 min), prioritaire sur le réglage général.
-- Un compte avec inactivite_min ne peut pas utiliser « rester connecté ».
alter table public.acces add column if not exists inactivite_min int check (inactivite_min is null or inactivite_min between 5 and 1440);
update public.acces set inactivite_min = 10 where identifiant = 'buvette';
-- api_connexion : inactivite_max = coalesce(acces.inactivite_min, réglage général) ; rester connecté refusé si inactivite_min défini.
