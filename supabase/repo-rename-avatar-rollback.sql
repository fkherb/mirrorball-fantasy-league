-- Emergency rollback ONLY after the old Pages site is restored.
-- Change 'no' to 'yes' after checking its images load.
begin;
set local mirrorball.repo_url_rollback_ready = 'no';
do $$ begin
  if current_setting('mirrorball.repo_url_rollback_ready', true) is distinct from 'yes' then
    raise exception 'Verify the old website is restored, then change repo_url_rollback_ready to yes';
  end if;
end $$;
update public.profiles
set avatar_url = 'https://fkherb.github.io/mirrorball-fantasy-league/' ||
  substr(avatar_url, length('https://fkherb.github.io/mirrorball-fantasy/') + 1)
where avatar_url like 'https://fkherb.github.io/mirrorball-fantasy/%';
update public.fantasy_teams
set avatar_url = 'https://fkherb.github.io/mirrorball-fantasy-league/' ||
  substr(avatar_url, length('https://fkherb.github.io/mirrorball-fantasy/') + 1)
where avatar_url like 'https://fkherb.github.io/mirrorball-fantasy/%';
commit;
