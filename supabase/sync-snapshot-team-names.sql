-- Team identity and weekly scoring stay frozen, but a team's display name is live.
-- Run once in the Supabase SQL editor. This updates existing names in both
-- snapshot tables and keeps them synchronized after future team renames.
begin;

create or replace function public.sync_snapshot_team_name()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.weekly_roster_snapshots snapshot
  set team_name = new.team_name
  where snapshot.fantasy_team_id = new.id
    and snapshot.team_name is distinct from new.team_name;

  update public.league_weekly_roster_snapshots snapshot
  set team_name = new.team_name
  where snapshot.fantasy_team_id = new.id
    and snapshot.team_name is distinct from new.team_name;

  return new;
end;
$$;

revoke all on function public.sync_snapshot_team_name() from public, anon, authenticated;

drop trigger if exists sync_snapshot_team_name on public.fantasy_teams;
create trigger sync_snapshot_team_name
after update of team_name on public.fantasy_teams
for each row
when (old.team_name is distinct from new.team_name)
execute function public.sync_snapshot_team_name();

update public.weekly_roster_snapshots snapshot
set team_name = team.team_name
from public.fantasy_teams team
where snapshot.fantasy_team_id = team.id
  and snapshot.team_name is distinct from team.team_name;

update public.league_weekly_roster_snapshots snapshot
set team_name = team.team_name
from public.fantasy_teams team
where snapshot.fantasy_team_id = team.id
  and snapshot.team_name is distinct from team.team_name;

commit;

-- Both values should be zero. The snapshot's team ID, role, rate, and points
-- are intentionally unchanged.
select
  (select count(*) from public.weekly_roster_snapshots snapshot
   join public.fantasy_teams team on team.id = snapshot.fantasy_team_id
   where snapshot.team_name is distinct from team.team_name) as legacy_name_mismatches,
  (select count(*) from public.league_weekly_roster_snapshots snapshot
   join public.fantasy_teams team on team.id = snapshot.fantasy_team_id
   where snapshot.team_name is distinct from team.team_name) as shared_name_mismatches;
