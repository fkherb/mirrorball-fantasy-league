-- add-team-pictures.sql
-- Each fantasy team can have its own picture, separate from the manager's
-- profile picture (a manager can use a different one in every league).
--
-- • fantasy_teams.avatar_url: an https URL, or null to fall back to the
--   manager's profile picture. Readable wherever the team already is.
-- • update_league_team_avatar(p_league_id, p_avatar_url): sets (or clears)
--   the caller's own team picture in that league.
-- • Uploads reuse the profile-pictures bucket (<user id>/<file>.jpg), whose
--   existing policy already lets a signed-in user upload into their folder.
--
-- Safe to run more than once.
begin;

alter table public.fantasy_teams add column if not exists avatar_url text;

alter table public.fantasy_teams drop constraint if exists fantasy_teams_avatar_url_check;
alter table public.fantasy_teams add constraint fantasy_teams_avatar_url_check check (
  avatar_url is null
  or (avatar_url = trim(avatar_url) and char_length(avatar_url) <= 2048 and avatar_url ~* '^https://')
);

create or replace function public.update_league_team_avatar(p_league_id uuid, p_avatar_url text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_url text := nullif(trim(coalesce(p_avatar_url, '')), '');
begin
  select fantasy_team_id into v_team_id
  from public.league_members
  where league_id = p_league_id and user_id = auth.uid() and status = 'active';

  if v_team_id is null then
    raise exception 'League membership required.';
  end if;
  if v_url is not null and (char_length(v_url) > 2048 or v_url !~* '^https://') then
    raise exception 'Team picture must be an https link.';
  end if;

  update public.fantasy_teams
  set avatar_url = v_url
  where id = v_team_id and league_id = p_league_id;
end;
$$;

revoke all on function public.update_league_team_avatar(uuid, text) from public, anon;
grant execute on function public.update_league_team_avatar(uuid, text) to authenticated;

commit;

notify pgrst, 'reload schema';
