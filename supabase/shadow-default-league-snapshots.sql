-- Prepare the original league for the shared scoring path without changing
-- its live reads or writes. Run after activate-multi-league-workspaces.sql.
-- Safe to rerun: existing shared rows are reconciled to their legacy source.
begin;

create or replace function public.mirror_default_league_week_snapshot()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.league_id = public.default_fantasy_league_id() then
    insert into public.league_weekly_roster_snapshots
      (league_id, week_id, cast_member_id, fantasy_team_id,
       cast_member_name, cast_role, appearance_points, manager_name, team_name, created_at)
    values
      (new.league_id, new.week_id, new.cast_member_id, new.fantasy_team_id,
       new.cast_member_name, new.cast_role, new.appearance_points,
       new.manager_name, new.team_name, new.created_at)
    on conflict (league_id, week_id, cast_member_id) do update set
      fantasy_team_id = excluded.fantasy_team_id,
      cast_member_name = excluded.cast_member_name,
      cast_role = excluded.cast_role,
      appearance_points = excluded.appearance_points,
      manager_name = excluded.manager_name,
      team_name = excluded.team_name,
      created_at = excluded.created_at;
  end if;
  return new;
end;
$$;
revoke all on function public.mirror_default_league_week_snapshot() from public, anon, authenticated;
drop trigger if exists mirror_default_league_week_snapshot on public.weekly_roster_snapshots;
create trigger mirror_default_league_week_snapshot
after insert or update on public.weekly_roster_snapshots
for each row execute function public.mirror_default_league_week_snapshot();

insert into public.league_weekly_roster_snapshots
  (league_id, week_id, cast_member_id, fantasy_team_id,
   cast_member_name, cast_role, appearance_points, manager_name, team_name, created_at)
select legacy.league_id, legacy.week_id, legacy.cast_member_id,
  legacy.fantasy_team_id, legacy.cast_member_name, legacy.cast_role,
  legacy.appearance_points, legacy.manager_name, legacy.team_name, legacy.created_at
from public.weekly_roster_snapshots legacy
where legacy.league_id = public.default_fantasy_league_id()
on conflict (league_id, week_id, cast_member_id) do update set
  fantasy_team_id = excluded.fantasy_team_id,
  cast_member_name = excluded.cast_member_name,
  cast_role = excluded.cast_role,
  appearance_points = excluded.appearance_points,
  manager_name = excluded.manager_name,
  team_name = excluded.team_name,
  created_at = excluded.created_at;

commit;
