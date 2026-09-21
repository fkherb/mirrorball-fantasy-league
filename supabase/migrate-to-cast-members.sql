-- Run once in Supabase Dashboard → SQL Editor, before loading the refactored site.
-- It preserves every existing cast member, pairing, score, and team assignment.
do $$
begin
  if to_regclass('public.players') is not null and to_regclass('public.cast_members') is null then
    alter table public.players rename to cast_members;
  end if;
end $$;

alter table public.cast_members
add column if not exists fantasy_team_id uuid references public.fantasy_teams(id) on delete set null;

-- Carry current legacy assignments into the new, direct team-membership field.
update public.cast_members as cast_member
set fantasy_team_id = legacy.fantasy_team_id
from (
  select distinct on (player_id) player_id, fantasy_team_id
  from public.roster_history
  where ends_week_id is null and fantasy_team_id is not null
  order by player_id
) as legacy
where legacy.player_id = cast_member.id
  and cast_member.fantasy_team_id is null;

-- roster_history is deliberately preserved but is no longer read or written by the app.
-- Use it later only for explicit trade/history features.
