create or replace function public.api_tmp_migrations(p_cle text)
returns jsonb language plpgsql security definer set search_path = public, extensions, supabase_migrations as $$
begin
  if p_cle is distinct from 'xport-7Qm2Lw9Rt4Ka' then return '[]'::jsonb; end if;
  return (select jsonb_agg(jsonb_build_object('version', version, 'name', name, 'sql', array_to_string(statements, E';\n')) order by version) from supabase_migrations.schema_migrations);
end $$;
revoke execute on function public.api_tmp_migrations(text) from public, authenticated;
grant execute on function public.api_tmp_migrations(text) to anon;
;
