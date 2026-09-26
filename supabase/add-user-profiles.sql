-- Mirrorball Fantasy League: canonical user profiles and usernames.
--
-- Prerequisite: run prepare-multi-league-foundation.sql first.
-- This migration never changes auth.users.id or the existing authentication flow.
-- Existing league-member and fantasy-team name fields remain as synchronized
-- compatibility columns while the application moves to profiles.

begin;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  display_name text not null,
  avatar_url text,
  onboarding_completed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_format_check check (
    username = lower(username)
    and char_length(username) between 3 and 20
    and username ~ '^[a-z0-9_]+$'
  ),
  constraint profiles_display_name_check check (
    display_name = trim(display_name)
    and char_length(display_name) between 1 and 80
  ),
  constraint profiles_avatar_url_check check (
    avatar_url is null
    or (
      avatar_url = trim(avatar_url)
      and char_length(avatar_url) <= 2048
      and avatar_url ~* '^https://'
    )
  )
);

-- The functional index is intentional even though stored usernames are forced
-- lowercase. It makes case-insensitive uniqueness explicit at the database layer.
create unique index if not exists profiles_username_lower_key
  on public.profiles (lower(username));

create or replace function public.profile_username_base(p_seed text, p_user_id uuid)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_base text;
begin
  v_base := regexp_replace(lower(coalesce(p_seed, '')), '[^a-z0-9_]+', '', 'g');
  v_base := left(v_base, 20);
  if char_length(v_base) < 3 then
    v_base := left(v_base || replace(p_user_id::text, '-', ''), 20);
  end if;
  if char_length(v_base) < 3 then v_base := rpad(v_base, 3, '_'); end if;
  return v_base;
end;
$$;

revoke all on function public.profile_username_base(text, uuid) from public, anon, authenticated;

create or replace function public.next_profile_username(p_seed text, p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base text := public.profile_username_base(p_seed, p_user_id);
  v_candidate text := v_base;
  v_suffix integer := 1;
  v_suffix_text text;
begin
  while exists (select 1 from public.profiles where lower(username) = lower(v_candidate)) loop
    v_suffix := v_suffix + 1;
    v_suffix_text := v_suffix::text;
    v_candidate := left(v_base, 20 - char_length(v_suffix_text)) || v_suffix_text;
  end loop;
  return v_candidate;
end;
$$;

revoke all on function public.next_profile_username(text, uuid) from public, anon, authenticated;

create or replace function public.profile_display_name_from_auth(p_user auth.users)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select left(coalesce(
    nullif(trim(p_user.raw_user_meta_data ->> 'display_name'), ''),
    nullif(trim(p_user.raw_user_meta_data ->> 'full_name'), ''),
    nullif(trim(p_user.raw_user_meta_data ->> 'name'), ''),
    nullif(trim(concat_ws(' ', p_user.raw_user_meta_data ->> 'first_name', p_user.raw_user_meta_data ->> 'last_name')), ''),
    nullif(split_part(coalesce(p_user.email, ''), '@', 1), ''),
    'User'
  ), 80);
$$;

revoke all on function public.profile_display_name_from_auth(auth.users) from public, anon, authenticated;

-- Backfill in a stable order so collisions always resolve the same way:
-- oldest Auth account first, then UUID. Existing UUIDs are copied exactly.
do $$
declare
  v_user auth.users;
  v_display_name text;
  v_seed text;
  v_username text;
begin
  for v_user in
    select auth_user.*
    from auth.users auth_user
    left join public.profiles profile on profile.user_id = auth_user.id
    where profile.user_id is null
    order by auth_user.created_at, auth_user.id
  loop
    -- Prefer the manager name already shown in the league, then fall back to
    -- Auth metadata. This preserves the currently visible identity at cutover.
    v_display_name := left(coalesce(
      (
        select nullif(trim(concat_ws(' ', member.first_name, member.last_name)), '')
        from public.league_members member
        where member.user_id = v_user.id
        order by member.created_at, member.league_id
        limit 1
      ),
      public.profile_display_name_from_auth(v_user)
    ), 80);
    v_seed := coalesce(
      (
        select nullif(trim(member.first_name), '')
        from public.league_members member
        where member.user_id = v_user.id
        order by member.created_at, member.league_id
        limit 1
      ),
      nullif(trim(v_user.raw_user_meta_data ->> 'first_name'), ''),
      nullif(split_part(v_display_name, ' ', 1), ''),
      nullif(split_part(coalesce(v_user.email, ''), '@', 1), ''),
      'user'
    );
    v_username := public.next_profile_username(v_seed, v_user.id);

    insert into public.profiles (user_id, username, display_name, onboarding_completed, created_at, updated_at)
    values (v_user.id, v_username, v_display_name, false, coalesce(v_user.created_at, now()), now())
    on conflict (user_id) do nothing;
  end loop;
end;
$$;

create or replace function public.create_profile_for_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name text;
  v_seed text;
  v_username text;
begin
  v_display_name := public.profile_display_name_from_auth(new);
  v_seed := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'first_name'), ''),
    nullif(split_part(v_display_name, ' ', 1), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'user'
  );

  -- The unique index is the final concurrency guard. Retry with the next suffix
  -- if two signups choose the same base between lookup and insert.
  loop
    v_username := public.next_profile_username(v_seed, new.id);
    begin
      insert into public.profiles (user_id, username, display_name)
      values (new.id, v_username, v_display_name)
      on conflict (user_id) do nothing;
      exit;
    exception when unique_violation then
      continue;
    end;
  end loop;
  return new;
end;
$$;

revoke all on function public.create_profile_for_auth_user() from public, anon, authenticated;
drop trigger if exists create_profile_after_auth_signup on auth.users;
create trigger create_profile_after_auth_signup
after insert on auth.users
for each row execute function public.create_profile_for_auth_user();

create or replace function public.set_profile_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.set_profile_updated_at() from public, anon, authenticated;
drop trigger if exists set_profile_updated_at on public.profiles;
create trigger set_profile_updated_at
before update on public.profiles
for each row execute function public.set_profile_updated_at();

-- Compatibility identity fields may be absent for a one-word display name.
alter table public.league_members alter column first_name drop not null;
alter table public.league_members alter column last_name drop not null;
alter table public.league_members drop constraint if exists league_members_first_name_check;
alter table public.league_members drop constraint if exists league_members_last_name_check;
alter table public.league_members drop constraint if exists league_members_first_name_length_check;
alter table public.league_members drop constraint if exists league_members_last_name_length_check;
alter table public.league_members add constraint league_members_first_name_length_check
  check (first_name is null or char_length(trim(first_name)) between 1 and 40) not valid;
alter table public.league_members add constraint league_members_last_name_length_check
  check (last_name is null or char_length(trim(last_name)) between 1 and 50) not valid;

-- Display names are not handles and do not need to be unique.
drop index if exists public.fantasy_teams_league_manager_name_key;
alter table public.fantasy_teams drop constraint if exists fantasy_teams_manager_name_key;

create or replace function public.sync_profile_compatibility_names()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_first_name text;
  v_last_name text;
begin
  v_first_name := left(split_part(new.display_name, ' ', 1), 40);
  v_last_name := nullif(left(trim(substr(new.display_name, char_length(split_part(new.display_name, ' ', 1)) + 1)), 50), '');

  update public.league_members
  set first_name = v_first_name,
      last_name = v_last_name,
      updated_at = now()
  where user_id = new.user_id;

  update public.fantasy_teams team
  set manager_name = new.display_name
  from public.league_members member
  where member.user_id = new.user_id
    and member.fantasy_team_id = team.id;
  return new;
end;
$$;

revoke all on function public.sync_profile_compatibility_names() from public, anon, authenticated;
drop trigger if exists sync_profile_compatibility_names on public.profiles;
create trigger sync_profile_compatibility_names
after insert or update of display_name on public.profiles
for each row execute function public.sync_profile_compatibility_names();

-- Prevent old SQL clients or direct table writes from turning compatibility
-- fields back into independent identity sources.
create or replace function public.enforce_member_profile_name()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name text;
begin
  select display_name into v_display_name from public.profiles where user_id = new.user_id;
  if v_display_name is not null then
    new.first_name := left(split_part(v_display_name, ' ', 1), 40);
    new.last_name := nullif(left(trim(substr(v_display_name, char_length(split_part(v_display_name, ' ', 1)) + 1)), 50), '');
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_member_profile_name() from public, anon, authenticated;
drop trigger if exists enforce_member_profile_name on public.league_members;
create trigger enforce_member_profile_name
before insert or update of user_id, first_name, last_name on public.league_members
for each row execute function public.enforce_member_profile_name();

create or replace function public.enforce_team_profile_name()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name text;
begin
  select profile.display_name into v_display_name
  from public.league_members member
  join public.profiles profile on profile.user_id = member.user_id
  where member.fantasy_team_id = new.id
  limit 1;
  if v_display_name is not null then new.manager_name := v_display_name; end if;
  return new;
end;
$$;

revoke all on function public.enforce_team_profile_name() from public, anon, authenticated;
drop trigger if exists enforce_team_profile_name on public.fantasy_teams;
create trigger enforce_team_profile_name
before insert or update of manager_name on public.fantasy_teams
for each row execute function public.enforce_team_profile_name();

-- Sync all existing compatibility fields once after backfill.
update public.profiles set display_name = display_name;

alter table public.profiles enable row level security;
drop policy if exists "profiles are discoverable" on public.profiles;
create policy "profiles are discoverable" on public.profiles
for select to anon, authenticated using (true);
drop policy if exists "users update own profile" on public.profiles;
create policy "users update own profile" on public.profiles
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

revoke all on public.profiles from public, anon, authenticated;
grant select (user_id, username, display_name, avatar_url) on public.profiles to anon, authenticated;
grant update (username, display_name, avatar_url, onboarding_completed) on public.profiles to authenticated;

create or replace view public.profile_directory
with (security_invoker = true)
as select user_id, username, display_name, avatar_url from public.profiles;
revoke all on public.profile_directory from public;
grant select on public.profile_directory to anon, authenticated;

create or replace function public.update_my_profile(
  p_username text,
  p_display_name text,
  p_avatar_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_username text := lower(trim(coalesce(p_username, '')));
  v_display_name text := trim(coalesce(p_display_name, ''));
  v_avatar_url text := nullif(trim(coalesce(p_avatar_url, '')), '');
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if v_username !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'Username must be 3–20 characters using lowercase letters, numbers, or underscores.';
  end if;
  if char_length(v_display_name) not between 1 and 80 then
    raise exception 'Display name must be between 1 and 80 characters.';
  end if;
  if v_avatar_url is not null and (char_length(v_avatar_url) > 2048 or v_avatar_url !~* '^https://') then
    raise exception 'Avatar URL must be a valid HTTPS address.';
  end if;

  update public.profiles
  set username = v_username,
      display_name = v_display_name,
      avatar_url = v_avatar_url,
      onboarding_completed = true
  where user_id = auth.uid()
  returning * into v_profile;

  if v_profile.user_id is null then raise exception 'Your profile could not be found.'; end if;
  return to_jsonb(v_profile);
exception when unique_violation then
  raise exception 'That username is already taken.';
end;
$$;

revoke all on function public.update_my_profile(text,text,text) from public, anon;
grant execute on function public.update_my_profile(text,text,text) to authenticated;

create or replace function public.get_my_account_context()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'profile', (select to_jsonb(profile) from public.profiles profile where profile.user_id = auth.uid()),
    'membership', (
      select to_jsonb(member)
      from public.league_members member
      where member.user_id = auth.uid()
        and member.league_id = public.default_fantasy_league_id()
      limit 1
    ),
    'team_name', (
      select team.team_name
      from public.league_members member
      join public.fantasy_teams team on team.id = member.fantasy_team_id
      where member.user_id = auth.uid()
        and member.league_id = public.default_fantasy_league_id()
      limit 1
    )
  ) end;
$$;

revoke all on function public.get_my_account_context() from public, anon;
grant execute on function public.get_my_account_context() to authenticated;

drop function if exists public.get_league_team_managers();
create function public.get_league_team_managers()
returns table (fantasy_team_id uuid, user_id uuid, username text, display_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select member.fantasy_team_id, profile.user_id, profile.username, profile.display_name
  from public.league_members member
  join public.profiles profile on profile.user_id = member.user_id
  where member.league_id = public.default_fantasy_league_id()
    and member.fantasy_team_id is not null;
$$;

revoke all on function public.get_league_team_managers() from public;
grant execute on function public.get_league_team_managers() to anon, authenticated;

create or replace function public.update_my_team_settings(
  p_display_name text,
  p_team_name text,
  p_nav_label_mode text default 'default',
  p_custom_nav_label text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_league_id uuid := public.default_fantasy_league_id();
  v_team_id uuid;
  v_member public.league_members;
  v_display_name text := trim(coalesce(p_display_name, ''));
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if char_length(v_display_name) not between 1 and 80 then raise exception 'Display name must be between 1 and 80 characters.'; end if;
  if p_nav_label_mode not in ('default', 'team', 'custom') then raise exception 'Invalid My Team label option.'; end if;
  if p_nav_label_mode = 'team' and nullif(trim(coalesce(p_team_name, '')), '') is null then raise exception 'Add a team name first.'; end if;
  if p_nav_label_mode = 'custom' and nullif(trim(coalesce(p_custom_nav_label, '')), '') is null then raise exception 'Enter a custom My Team label.'; end if;

  select fantasy_team_id into v_team_id
  from public.league_members
  where league_id = v_league_id and user_id = auth.uid();
  if v_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;

  update public.profiles set display_name = v_display_name where user_id = auth.uid();
  update public.league_members
  set team_nav_label_mode = p_nav_label_mode,
      custom_team_nav_label = case when p_nav_label_mode = 'custom' then trim(p_custom_nav_label) else null end,
      updated_at = now()
  where league_id = v_league_id and user_id = auth.uid()
  returning * into v_member;
  update public.fantasy_teams set team_name = nullif(trim(coalesce(p_team_name, '')), '') where id = v_team_id;

  return jsonb_build_object('membership', to_jsonb(v_member), 'team_name', nullif(trim(coalesce(p_team_name, '')), ''));
end;
$$;

revoke all on function public.update_my_team_settings(text,text,text,text) from public, anon;
grant execute on function public.update_my_team_settings(text,text,text,text) to authenticated;

create or replace function public.update_team_profile_from_profile(
  p_team_id uuid,
  p_team_name text,
  p_manager_user_id uuid default null,
  p_display_name text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_league_id uuid := public.default_fantasy_league_id();
begin
  if auth.uid() is null or not exists (
    select 1 from public.league_members
    where league_id = v_league_id and user_id = auth.uid() and is_commissioner
  ) then raise exception 'Commissioner access is required.'; end if;
  if not exists (select 1 from public.fantasy_teams where id = p_team_id and league_id = v_league_id) then
    raise exception 'Fantasy team not found.';
  end if;
  if char_length(trim(coalesce(p_team_name, ''))) > 80 then raise exception 'Team name must be 80 characters or fewer.'; end if;
  if p_manager_user_id is not null then
    if not exists (
      select 1 from public.league_members
      where league_id = v_league_id and user_id = p_manager_user_id and fantasy_team_id = p_team_id
    ) then raise exception 'That manager is not connected to this fantasy team.'; end if;
    if char_length(trim(coalesce(p_display_name, ''))) not between 1 and 80 then raise exception 'Display name must be between 1 and 80 characters.'; end if;
    update public.profiles set display_name = trim(p_display_name) where user_id = p_manager_user_id;
    if not found then raise exception 'That manager profile could not be found.'; end if;
  end if;
  update public.fantasy_teams set team_name = nullif(trim(coalesce(p_team_name, '')), '') where id = p_team_id;
  if not found then raise exception 'Fantasy team not found.'; end if;
end;
$$;

revoke all on function public.update_team_profile_from_profile(uuid,text,uuid,text) from public, anon;
grant execute on function public.update_team_profile_from_profile(uuid,text,uuid,text) to authenticated;

-- Compatibility wrappers keep older cached clients safe while profiles become
-- canonical. They no longer write Auth metadata or independent name copies.
create or replace function public.update_my_league_name(p_first_name text, p_last_name text)
returns public.league_members
language plpgsql
security definer
set search_path = ''
as $$
declare v_member public.league_members;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  update public.profiles
  set display_name = trim(concat_ws(' ', nullif(trim(p_first_name), ''), nullif(trim(p_last_name), '')))
  where user_id = auth.uid();
  select * into v_member from public.league_members
  where league_id = public.default_fantasy_league_id() and user_id = auth.uid();
  if v_member.user_id is null then raise exception 'This account has not been added to the league.'; end if;
  return v_member;
end;
$$;

create or replace function public.update_my_team_profile(
  p_first_name text, p_last_name text, p_team_name text,
  p_nav_label_mode text default 'default', p_custom_nav_label text default null
)
returns public.league_members
language plpgsql
security definer
set search_path = ''
as $$
declare v_member public.league_members;
begin
  perform public.update_my_team_settings(
    trim(concat_ws(' ', nullif(trim(p_first_name), ''), nullif(trim(p_last_name), ''))),
    p_team_name, p_nav_label_mode, p_custom_nav_label
  );
  select * into v_member from public.league_members
  where league_id = public.default_fantasy_league_id() and user_id = auth.uid();
  return v_member;
end;
$$;

create or replace function public.update_team_profile_atomic(
  p_team_id uuid, p_team_name text, p_manager_user_id uuid default null,
  p_first_name text default null, p_last_name text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.update_team_profile_from_profile(
    p_team_id, p_team_name, p_manager_user_id,
    case when p_manager_user_id is null then null
         else trim(concat_ws(' ', nullif(trim(p_first_name), ''), nullif(trim(p_last_name), ''))) end
  );
end;
$$;

revoke all on function public.update_my_league_name(text,text) from public, anon;
grant execute on function public.update_my_league_name(text,text) to authenticated;
revoke all on function public.update_my_team_profile(text,text,text,text,text) from public, anon;
grant execute on function public.update_my_team_profile(text,text,text,text,text) to authenticated;
revoke all on function public.update_team_profile_atomic(uuid,text,uuid,text,text) from public, anon;
grant execute on function public.update_team_profile_atomic(uuid,text,uuid,text,text) to authenticated;

commit;

notify pgrst, 'reload schema';
