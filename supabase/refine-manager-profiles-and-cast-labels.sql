-- Manager display preferences and judge/host display labels.
-- Safe to run more than once in the Supabase SQL editor.

alter table public.league_members
  add column if not exists team_nav_label_mode text not null default 'default',
  add column if not exists custom_team_nav_label text;

alter table public.cast_members
  add column if not exists role_detail text,
  add column if not exists is_hough boolean not null default false;

-- Hough is now a scoring modifier within the Judges + Hosts category.
update public.cast_members
set role = 'Judges + Hosts',
    role_detail = coalesce(role_detail, 'Judge + Host'),
    is_hough = true
where role = 'Hough';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'league_members_team_nav_label_mode_check') then
    alter table public.league_members add constraint league_members_team_nav_label_mode_check
      check (team_nav_label_mode in ('default', 'team', 'custom'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cast_members_role_detail_check') then
    alter table public.cast_members add constraint cast_members_role_detail_check
      check (role_detail is null or role_detail in ('Judge', 'Host', 'Judge + Host'));
  end if;
end $$;

create or replace function public.get_league_team_managers()
returns table (fantasy_team_id uuid, first_name text, last_name text)
language sql
security definer
set search_path = public
stable
as $$
  select lm.fantasy_team_id, lm.first_name, lm.last_name
  from public.league_members lm
  where lm.fantasy_team_id is not null;
$$;

revoke all on function public.get_league_team_managers() from public;
grant execute on function public.get_league_team_managers() to anon, authenticated;

create or replace function public.update_my_team_profile(
  p_first_name text,
  p_last_name text,
  p_team_name text,
  p_nav_label_mode text default 'default',
  p_custom_nav_label text default null
)
returns public.league_members
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_member public.league_members;
  member_team_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if nullif(trim(p_first_name), '') is null or nullif(trim(p_last_name), '') is null then
    raise exception 'First and last name are required.';
  end if;
  if p_nav_label_mode not in ('default', 'team', 'custom') then raise exception 'Invalid My Team label option.'; end if;
  if p_nav_label_mode = 'custom' and nullif(trim(p_custom_nav_label), '') is null then
    raise exception 'Enter a custom My Team label.';
  end if;

  select fantasy_team_id into member_team_id from public.league_members where user_id = auth.uid();
  if member_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;

  update public.league_members
  set first_name = trim(p_first_name),
      last_name = trim(p_last_name),
      team_nav_label_mode = p_nav_label_mode,
      custom_team_nav_label = case when p_nav_label_mode = 'custom' then trim(p_custom_nav_label) else null end,
      updated_at = now()
  where user_id = auth.uid()
  returning * into updated_member;

  update public.fantasy_teams
  set team_name = nullif(trim(p_team_name), '')
  where id = member_team_id;

  return updated_member;
end;
$$;

revoke all on function public.update_my_team_profile(text,text,text,text,text) from public;
grant execute on function public.update_my_team_profile(text,text,text,text,text) to authenticated;

notify pgrst, 'reload schema';
