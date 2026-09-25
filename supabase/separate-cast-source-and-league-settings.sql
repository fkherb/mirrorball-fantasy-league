-- Mirrorball Fantasy League: separate canonical cast administration from
-- league commissioner tools, add league naming, cast profiles, and a true
-- season-finale marker. Run once after separate-platform-score-desk.sql.

begin;

alter table public.cast_members add column if not exists bio text;
alter table public.cast_members add column if not exists career_highlights text;
alter table public.cast_members add column if not exists mirrorball_wins integer not null default 0;
alter table public.cast_members add column if not exists profile_details jsonb not null default '{}'::jsonb;
alter table public.cast_members drop constraint if exists cast_members_mirrorball_wins_check;
alter table public.cast_members add constraint cast_members_mirrorball_wins_check check (mirrorball_wins between 0 and 99);

alter table public.weeks add column if not exists is_season_finale boolean not null default false;
create unique index if not exists one_season_finale on public.weeks (is_season_finale) where is_season_finale;

create or replace function public.validate_season_finale_week()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' and exists (select 1 from public.weeks where is_season_finale) then
    raise exception 'The season finale is already scheduled. Unmark it before adding another week.';
  end if;
  if new.is_season_finale and exists (select 1 from public.weeks where id <> new.id and number > new.number) then
    raise exception 'Only the last scheduled week can be marked as the season finale.';
  end if;
  return new;
end;
$$;
drop trigger if exists validate_season_finale_week_trigger on public.weeks;
create trigger validate_season_finale_week_trigger before insert or update of is_season_finale on public.weeks
for each row execute function public.validate_season_finale_week();

create table if not exists public.league_settings (
  id smallint primary key default 1 check (id = 1),
  league_name text not null default 'DWTS Fantasy League' check (char_length(trim(league_name)) between 1 and 80),
  updated_at timestamptz not null default now()
);
insert into public.league_settings (id, league_name) values (1, 'DWTS Fantasy League') on conflict (id) do nothing;
alter table public.league_settings enable row level security;
drop policy if exists "public reads league settings" on public.league_settings;
create policy "public reads league settings" on public.league_settings for select to anon, authenticated using (true);
drop policy if exists "commissioner writes league settings" on public.league_settings;
create policy "commissioner writes league settings" on public.league_settings for all to authenticated
  using (public.is_league_commissioner()) with check (public.is_league_commissioner());
grant select on public.league_settings to anon, authenticated;

-- Cast identity, roles, partnerships, and profile facts are canonical show
-- data. Commissioners can still assign that cast to fantasy teams only via
-- the narrow RPCs below.
drop policy if exists "commissioner writes players" on public.cast_members;
drop policy if exists "commissioner writes cast members" on public.cast_members;
drop policy if exists "platform owner writes cast members" on public.cast_members;
create policy "platform owner writes cast members" on public.cast_members for all to authenticated
  using (public.is_platform_admin()) with check (public.is_platform_admin());

create or replace function public.assign_cast_members_to_team(p_team_id uuid, p_cast_member_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  if not exists (select 1 from public.fantasy_teams where id = p_team_id) then raise exception 'Fantasy team not found.'; end if;
  if coalesce(array_length(p_cast_member_ids, 1), 0) = 0 then raise exception 'Choose at least one cast member.'; end if;
  if exists (select 1 from public.cast_members where id = any(p_cast_member_ids) and fantasy_team_id is not null) then
    raise exception 'One or more selected cast members is already assigned.';
  end if;
  update public.cast_members set fantasy_team_id = p_team_id where id = any(p_cast_member_ids);
  if not found then raise exception 'No cast members were updated.'; end if;
end;
$$;

create or replace function public.remove_cast_member_from_team(p_cast_member_id uuid, p_team_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  update public.cast_members set fantasy_team_id = null where id = p_cast_member_id and fantasy_team_id = p_team_id;
  if not found then raise exception 'That cast member is not assigned to this team.'; end if;
end;
$$;

create or replace function public.update_cast_profile_details(
  p_cast_member_id uuid,
  p_bio text,
  p_career_highlights text,
  p_mirrorball_wins integer
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  if p_mirrorball_wins is null or p_mirrorball_wins < 0 or p_mirrorball_wins > 99 then raise exception 'Past wins must be from 0 to 99.'; end if;
  update public.cast_members set bio = nullif(trim(p_bio), ''), career_highlights = nullif(trim(p_career_highlights), ''), mirrorball_wins = p_mirrorball_wins where id = p_cast_member_id;
  if not found then raise exception 'Cast member not found.'; end if;
end;
$$;

create or replace function public.save_cast_member_profile_atomic(
  p_cast_member_id uuid,
  p_name text,
  p_role text,
  p_image_path text,
  p_image_position integer,
  p_custom_appearance_points integer,
  p_role_detail text,
  p_is_hough boolean,
  p_partner_id uuid,
  p_partnership_name text,
  p_bio text,
  p_career_highlights text,
  p_mirrorball_wins integer
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare v_member_id uuid;
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  if p_mirrorball_wins is null or p_mirrorball_wins < 0 or p_mirrorball_wins > 99 then raise exception 'Past wins must be from 0 to 99.'; end if;
  v_member_id := public.save_cast_member_atomic(p_cast_member_id, p_name, p_role, p_image_path, p_image_position,
    p_custom_appearance_points, p_role_detail, p_is_hough, p_partner_id, p_partnership_name);
  update public.cast_members set bio = nullif(trim(p_bio), ''), career_highlights = nullif(trim(p_career_highlights), ''), mirrorball_wins = p_mirrorball_wins
  where id = v_member_id;
  return v_member_id;
end;
$$;

create or replace function public.update_league_name(p_league_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  if nullif(trim(p_league_name), '') is null or char_length(trim(p_league_name)) > 80 then raise exception 'League name must be from 1 to 80 characters.'; end if;
  insert into public.league_settings (id, league_name, updated_at) values (1, trim(p_league_name), now())
  on conflict (id) do update set league_name = excluded.league_name, updated_at = excluded.updated_at;
end;
$$;
revoke insert, update, delete on public.league_settings from anon, authenticated;
revoke all on function public.update_league_name(text) from public, anon;
grant execute on function public.update_league_name(text) to authenticated;

create or replace function public.set_week_season_finale(p_week_id uuid, p_is_season_finale boolean)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare v_week_number integer; v_last_number integer;
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  select number into v_week_number from public.weeks where id = p_week_id for update;
  if v_week_number is null then raise exception 'Week not found.'; end if;
  select max(number) into v_last_number from public.weeks;
  if p_is_season_finale and v_week_number <> v_last_number then raise exception 'Only the last scheduled week can be marked as the season finale.'; end if;
  if coalesce(p_is_season_finale, false) then
    update public.weeks set is_season_finale = false where is_season_finale and id <> p_week_id;
  end if;
  update public.weeks set is_season_finale = coalesce(p_is_season_finale, false) where id = p_week_id;
end;
$$;

create or replace function public.update_week_setup_and_finale(
  p_week_id uuid,
  p_theme text,
  p_title text,
  p_guest_judge_name text,
  p_double_elimination boolean,
  p_is_finale boolean,
  p_dance_ids uuid[],
  p_air_date date,
  p_second_air_date date,
  p_is_season_finale boolean
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  perform public.update_week_setup_dates_and_order(p_week_id, p_theme, p_title, p_guest_judge_name, p_double_elimination, p_is_finale, p_dance_ids, p_air_date, p_second_air_date);
  perform public.set_week_season_finale(p_week_id, p_is_season_finale);
end;
$$;

create or replace function public.update_completed_week_details_and_finale(
  p_week_id uuid,
  p_theme text,
  p_title text,
  p_air_date date,
  p_second_air_date date,
  p_guest_judge_name text,
  p_double_elimination boolean,
  p_is_finale boolean,
  p_is_season_finale boolean
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  perform public.update_completed_week_details(p_week_id, p_theme, p_title, p_air_date, p_second_air_date, p_guest_judge_name, p_double_elimination, p_is_finale);
  perform public.set_week_season_finale(p_week_id, p_is_season_finale);
end;
$$;

revoke all on function public.assign_cast_members_to_team(uuid,uuid[]) from public, anon;
revoke all on function public.remove_cast_member_from_team(uuid,uuid) from public, anon;
revoke all on function public.update_cast_profile_details(uuid,text,text,integer) from public, anon;
revoke all on function public.save_cast_member_profile_atomic(uuid,text,text,text,integer,integer,text,boolean,uuid,text,text,text,integer) from public, anon;
revoke all on function public.update_league_name(text) from public, anon;
revoke all on function public.set_week_season_finale(uuid,boolean) from public, anon;
revoke all on function public.update_week_setup_and_finale(uuid,text,text,text,boolean,boolean,uuid[],date,date,boolean) from public, anon;
revoke all on function public.update_completed_week_details_and_finale(uuid,text,text,date,date,text,boolean,boolean,boolean) from public, anon;
grant execute on function public.assign_cast_members_to_team(uuid,uuid[]) to authenticated;
grant execute on function public.remove_cast_member_from_team(uuid,uuid) to authenticated;
grant execute on function public.update_cast_profile_details(uuid,text,text,integer) to authenticated;
grant execute on function public.save_cast_member_profile_atomic(uuid,text,text,text,integer,integer,text,boolean,uuid,text,text,text,integer) to authenticated;
grant execute on function public.update_league_name(text) to authenticated;
grant execute on function public.set_week_season_finale(uuid,boolean) to authenticated;
grant execute on function public.update_week_setup_and_finale(uuid,text,text,text,boolean,boolean,uuid[],date,date,boolean) to authenticated;
grant execute on function public.update_completed_week_details_and_finale(uuid,text,text,date,date,text,boolean,boolean,boolean) to authenticated;

commit;
notify pgrst, 'reload schema';
