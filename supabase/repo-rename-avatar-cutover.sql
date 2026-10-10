-- CUTOVER ONLY: first verify the new Pages site and its avatar images load.
-- Change the following 'no' to 'yes' only after that check.
-- Exact URL-prefix update only; no schema/auth/league/scoring changes.
-- Idempotent: rerunning does not change already-migrated or unrelated URLs.
begin;
set local mirrorball.repo_url_cutover_ready = 'no';
do $$ begin
  if current_setting('mirrorball.repo_url_cutover_ready', true) is distinct from 'yes' then
    raise exception 'Verify the new website is live, then change repo_url_cutover_ready to yes';
  end if;
end $$;

with changed as (
  update public.profiles
  set avatar_url = 'https://fkherb.github.io/mirrorball-fantasy/' ||
    substr(avatar_url, length('https://fkherb.github.io/mirrorball-fantasy-league/') + 1)
  where avatar_url like 'https://fkherb.github.io/mirrorball-fantasy-league/%'
  returning user_id
) select 'profiles' as table_name, count(*) as updated_avatars from changed;

with changed as (
  update public.fantasy_teams
  set avatar_url = 'https://fkherb.github.io/mirrorball-fantasy/' ||
    substr(avatar_url, length('https://fkherb.github.io/mirrorball-fantasy-league/') + 1)
  where avatar_url like 'https://fkherb.github.io/mirrorball-fantasy-league/%'
  returning id
) select 'fantasy_teams' as table_name, count(*) as updated_avatars from changed;
commit;
