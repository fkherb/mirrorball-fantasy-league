-- Read-only. Safe before or after the rename. Run in the production SQL Editor.
select 'profiles.avatar_url' as field, count(*) as old_site_references
from public.profiles
where avatar_url like 'https://fkherb.github.io/mirrorball-fantasy-league/%'
union all
select 'fantasy_teams.avatar_url', count(*) from public.fantasy_teams
where avatar_url like 'https://fkherb.github.io/mirrorball-fantasy-league/%';

-- A rename should not need changes to scoring, draft, auth, or automation RPCs.
select n.nspname as schema_name, p.proname as function_name
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public', 'private')
  and (p.prosrc ilike '%mirrorball-fantasy-league%'
    or p.prosrc ilike '%fkherb.github.io%');
