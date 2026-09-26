-- Run after add-user-profiles.sql. This is the complete account, invitation,
-- draft, and league boundary for the website. It creates no extra league.
begin;

alter table public.leagues drop constraint if exists leagues_status_check;
alter table public.leagues add constraint leagues_status_check
  check (status in ('setup', 'drafting', 'active', 'archived'));
alter table public.leagues alter column status set default 'setup';
alter table public.leagues
  add column if not exists roster_size integer not null default 11,
  add column if not exists is_public boolean not null default false,
  add column if not exists draft_started_at timestamptz,
  add column if not exists draft_completed_at timestamptz,
  add column if not exists scoring_starts_after_week integer not null default 0;
alter table public.leagues drop constraint if exists leagues_roster_size_check;
alter table public.leagues add constraint leagues_roster_size_check check (roster_size between 1 and 30);
update public.leagues set is_public = true, status = 'active'
where id = public.default_fantasy_league_id();

alter table public.league_members
  add column if not exists role text not null default 'member',
  add column if not exists joined_at timestamptz not null default now(),
  add column if not exists status text not null default 'active';
alter table public.league_members drop constraint if exists league_members_role_check;
alter table public.league_members add constraint league_members_role_check
  check (role in ('owner', 'member'));
alter table public.league_members drop constraint if exists league_members_status_check;
alter table public.league_members add constraint league_members_status_check
  check (status in ('active', 'removed'));
update public.league_members set joined_at = created_at where joined_at > created_at;

-- Choose one existing owner deterministically. No account or team IDs change.
with chosen as (
  select member.user_id
  from public.league_members member
  join public.leagues league on league.id = member.league_id
  where member.league_id = public.default_fantasy_league_id()
  order by (member.user_id = league.created_by) desc,
           member.is_commissioner desc, member.created_at, member.user_id
  limit 1
)
update public.league_members member
set role = case when member.user_id = chosen.user_id then 'owner' else 'member' end,
    is_commissioner = member.user_id = chosen.user_id
from chosen
where member.league_id = public.default_fantasy_league_id();
create or replace function public.sync_legacy_commissioner_flag()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.is_commissioner := new.league_id = public.default_fantasy_league_id()
    and new.role = 'owner' and new.status = 'active';
  return new;
end;
$$;
revoke all on function public.sync_legacy_commissioner_flag() from public, anon, authenticated;
drop trigger if exists sync_legacy_commissioner_flag on public.league_members;
create trigger sync_legacy_commissioner_flag
before insert or update of league_id, role, status on public.league_members
for each row execute function public.sync_legacy_commissioner_flag();
create unique index if not exists league_members_one_owner_idx
  on public.league_members (league_id) where role = 'owner' and status = 'active';
create unique index if not exists league_members_league_team_key
  on public.league_members (league_id, fantasy_team_id)
  where fantasy_team_id is not null;
alter table public.league_members drop constraint if exists league_members_profile_user_id_fkey;
alter table public.league_members add constraint league_members_profile_user_id_fkey
  foreign key (user_id) references public.profiles(user_id) on delete cascade;
alter table public.league_members drop constraint if exists league_members_league_team_fkey;
alter table public.league_members add constraint league_members_league_team_fkey
  foreign key (league_id, fantasy_team_id)
  references public.fantasy_teams(league_id, id);

create or replace function public.is_league_member(p_league_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (
    select 1 from public.league_members
    where league_id = p_league_id and user_id = auth.uid() and status = 'active'
  );
$$;
create or replace function public.is_league_owner(p_league_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (
    select 1 from public.league_members
    where league_id = p_league_id and user_id = auth.uid()
      and role = 'owner' and status = 'active'
  );
$$;
create or replace function public.can_read_league(p_league_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.leagues where id = p_league_id and is_public)
    or public.is_league_member(p_league_id);
$$;
revoke all on function public.is_league_member(uuid), public.is_league_owner(uuid), public.can_read_league(uuid) from public;
grant execute on function public.is_league_member(uuid), public.is_league_owner(uuid), public.can_read_league(uuid) to anon, authenticated;

-- Legacy no-argument helpers always address the original league.
create or replace function public.is_league_commissioner()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.league_members
    where league_id = public.default_fantasy_league_id()
      and user_id = auth.uid() and status = 'active' and role = 'owner'
  );
$$;
create or replace function public.current_league_team_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select fantasy_team_id from public.league_members
  where league_id = public.default_fantasy_league_id()
    and user_id = auth.uid() and status = 'active' limit 1;
$$;
revoke all on function public.is_league_commissioner(), public.current_league_team_id() from public, anon;
grant execute on function public.is_league_commissioner(), public.current_league_team_id() to authenticated;

-- Replace cross-league read/write policies with league-aware boundaries.
drop policy if exists "public reads active leagues" on public.leagues;
create policy "read accessible leagues" on public.leagues for select to anon, authenticated
  using (is_public or public.is_league_member(id));
drop policy if exists "public read teams" on public.fantasy_teams;
drop policy if exists "public read fantasy teams" on public.fantasy_teams;
create policy "read accessible fantasy teams" on public.fantasy_teams for select to anon, authenticated
  using (public.can_read_league(league_id));
drop policy if exists "commissioner writes teams" on public.fantasy_teams;
create policy "legacy owner writes default teams" on public.fantasy_teams for all to authenticated
  using (league_id = public.default_fantasy_league_id() and public.is_league_commissioner())
  with check (league_id = public.default_fantasy_league_id() and public.is_league_commissioner());
drop policy if exists "members read own account" on public.league_members;
drop policy if exists "commissioner reads league members" on public.league_members;
drop policy if exists "commissioner manages league members" on public.league_members;
create policy "members read their league" on public.league_members for select to authenticated
  using (public.is_league_member(league_id));
revoke insert, update, delete on public.league_members from anon, authenticated;
drop policy if exists "public reads league roster assignments" on public.league_roster_assignments;
create policy "read accessible roster assignments" on public.league_roster_assignments
  for select to anon, authenticated using (public.can_read_league(league_id));
drop policy if exists "public reads league role rates" on public.league_role_rates;
create policy "read accessible role rates" on public.league_role_rates
  for select to anon, authenticated using (public.can_read_league(league_id));
drop policy if exists "public read weekly roster snapshots" on public.weekly_roster_snapshots;
create policy "read accessible weekly roster snapshots" on public.weekly_roster_snapshots
  for select to anon, authenticated using (public.can_read_league(league_id));
drop policy if exists "commissioner writes weekly roster snapshots" on public.weekly_roster_snapshots;
drop policy if exists "platform owner writes weekly roster snapshots" on public.weekly_roster_snapshots;
create policy "platform owner writes default snapshots" on public.weekly_roster_snapshots
  for all to authenticated
  using (league_id = public.default_fantasy_league_id() and public.is_platform_admin())
  with check (league_id = public.default_fantasy_league_id() and public.is_platform_admin());
drop policy if exists "public reads league settings" on public.league_settings;
drop policy if exists "commissioner writes league settings" on public.league_settings;
create policy "read accessible league settings" on public.league_settings
  for select to anon, authenticated using (public.can_read_league(league_id));

create or replace function public.get_my_leagues()
returns table (league_id uuid, name text, status text, roster_size integer,
               member_role text, fantasy_team_id uuid, team_name text,
               is_public boolean, scoring_starts_after_week integer)
language sql stable security definer set search_path = '' as $$
  select league.id, league.name, league.status, league.roster_size,
    member.role, member.fantasy_team_id, team.team_name,
    league.is_public, league.scoring_starts_after_week
  from public.league_members member
  join public.leagues league on league.id = member.league_id
  left join public.fantasy_teams team on team.id = member.fantasy_team_id
  where member.user_id = auth.uid() and member.status = 'active'
  order by member.joined_at, league.name;
$$;
revoke all on function public.get_my_leagues() from public, anon;
grant execute on function public.get_my_leagues() to authenticated;

create or replace function public.list_league_members(p_league_id uuid)
returns table (user_id uuid, username text, display_name text, avatar_url text,
               member_role text, fantasy_team_id uuid, team_name text, joined_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.can_read_league(p_league_id) then raise exception 'League access required.'; end if;
  return query select member.user_id, profile.username, profile.display_name,
    profile.avatar_url, member.role, member.fantasy_team_id, team.team_name,
    member.joined_at
  from public.league_members member
  join public.profiles profile on profile.user_id = member.user_id
  left join public.fantasy_teams team on team.id = member.fantasy_team_id
  where member.league_id = p_league_id and member.status = 'active'
  order by member.role desc, member.joined_at, profile.username;
end;
$$;
revoke all on function public.list_league_members(uuid) from public;
grant execute on function public.list_league_members(uuid) to anon, authenticated;

create or replace function public.create_fantasy_league(p_name text, p_roster_size integer default 11)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_profile public.profiles;
  v_team_id uuid;
  v_name text := trim(coalesce(p_name, ''));
begin
  if auth.uid() is null then raise exception 'Sign in to create a league.'; end if;
  select * into v_profile from public.profiles where user_id = auth.uid();
  if v_profile.user_id is null or not v_profile.onboarding_completed then
    raise exception 'Confirm your profile before creating a league.';
  end if;
  if char_length(v_name) not between 1 and 80 then raise exception 'League name must be 1–80 characters.'; end if;
  if p_roster_size not between 1 and 30 then raise exception 'Roster size must be 1–30.'; end if;

  insert into public.leagues (id, slug, name, created_by, status, roster_size)
  values (v_id, 'league-' || replace(v_id::text, '-', ''), v_name, auth.uid(), 'setup', p_roster_size);
  insert into public.fantasy_teams (league_id, manager_name, team_name)
  values (v_id, v_profile.display_name,
    left(split_part(v_profile.display_name, ' ', 1), 72) || '''s Team') returning id into v_team_id;
  insert into public.league_members
    (league_id, user_id, fantasy_team_id, role, first_name, last_name, is_commissioner)
  values (v_id, auth.uid(), v_team_id, 'owner',
    split_part(v_profile.display_name, ' ', 1),
    nullif(trim(substr(v_profile.display_name, char_length(split_part(v_profile.display_name, ' ', 1)) + 1)), ''), false);
  insert into public.league_role_rates (league_id, role_id, appearance_points)
  select v_id, role.id, coalesce(default_rate.appearance_points, role.appearance_points)
  from public.roles role
  left join public.league_role_rates default_rate
    on default_rate.league_id = public.default_fantasy_league_id() and default_rate.role_id = role.id;
  return v_id;
end;
$$;
revoke all on function public.create_fantasy_league(text,integer) from public, anon;
grant execute on function public.create_fantasy_league(text,integer) to authenticated;

create or replace function public.update_league_workspace(
  p_league_id uuid, p_name text, p_roster_size integer
)
returns void language plpgsql security definer set search_path = '' as $$
declare v_status text;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  select status into v_status from public.leagues where id = p_league_id for update;
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 80 then raise exception 'League name must be 1–80 characters.'; end if;
  if p_roster_size not between 1 and 30 then raise exception 'Roster size must be 1–30.'; end if;
  if v_status <> 'setup' and p_roster_size is distinct from
    (select roster_size from public.leagues where id = p_league_id) then
    raise exception 'Roster size is locked after the draft starts.';
  end if;
  update public.leagues set name = trim(p_name), roster_size = p_roster_size,
    updated_at = now() where id = p_league_id;
end;
$$;
revoke all on function public.update_league_workspace(uuid,text,integer) from public, anon;
grant execute on function public.update_league_workspace(uuid,text,integer) to authenticated;

create or replace function public.join_league_from_invite(p_league_id uuid, p_user_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_profile public.profiles; v_team_id uuid; v_status text;
begin
  if p_user_id is distinct from auth.uid() then raise exception 'You can only join as yourself.'; end if;
  select status into v_status from public.leagues where id = p_league_id for update;
  if v_status is null or v_status = 'archived' then raise exception 'League is unavailable.'; end if;
  if v_status <> 'setup' then raise exception 'This league has already started its draft.'; end if;
  if exists (select 1 from public.league_members where league_id = p_league_id and user_id = p_user_id) then
    raise exception 'You already belong to this league.';
  end if;
  select * into v_profile from public.profiles where user_id = p_user_id;
  if v_profile.user_id is null or not v_profile.onboarding_completed then
    raise exception 'Confirm your profile before joining a league.';
  end if;
  insert into public.fantasy_teams (league_id, manager_name, team_name)
  values (p_league_id, v_profile.display_name,
    left(split_part(v_profile.display_name, ' ', 1), 72) || '''s Team') returning id into v_team_id;
  insert into public.league_members
    (league_id, user_id, fantasy_team_id, role, first_name, last_name)
  values (p_league_id, p_user_id, v_team_id, 'member',
    split_part(v_profile.display_name, ' ', 1),
    nullif(trim(substr(v_profile.display_name, char_length(split_part(v_profile.display_name, ' ', 1)) + 1)), ''));
  return v_team_id;
end;
$$;
revoke all on function public.join_league_from_invite(uuid,uuid) from public, anon, authenticated;

create table if not exists public.league_invites (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  inviter_id uuid not null references public.profiles(user_id),
  invitee_id uuid not null references public.profiles(user_id),
  status text not null default 'pending' check (status in ('pending','accepted','declined','cancelled')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  expires_at timestamptz not null default (now() + interval '14 days'),
  check (inviter_id <> invitee_id)
);
create unique index if not exists league_invites_one_pending_idx
  on public.league_invites (league_id, invitee_id) where status = 'pending';
create index if not exists league_invites_inbox_idx
  on public.league_invites (invitee_id, status, created_at desc);
alter table public.league_invites enable row level security;
create policy "involved users read invitations" on public.league_invites
  for select to authenticated using
  (invitee_id = auth.uid() or public.is_league_owner(league_id));
revoke all on public.league_invites from public, anon, authenticated;
grant select on public.league_invites to authenticated;

create or replace function public.invite_username(p_league_id uuid, p_username text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_invitee uuid; v_id uuid;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  perform 1 from public.leagues where id = p_league_id for update;
  if (select status from public.leagues where id = p_league_id) <> 'setup' then
    raise exception 'Invitations are available before the draft starts.';
  end if;
  select user_id into v_invitee from public.profiles
  where username = lower(trim(coalesce(p_username, '')));
  if v_invitee is null then raise exception 'Username not found.'; end if;
  if exists (select 1 from public.league_members where league_id = p_league_id and user_id = v_invitee) then
    raise exception 'That person already belongs to this league.';
  end if;
  update public.league_invites set status = 'cancelled', responded_at = now()
  where league_id = p_league_id and invitee_id = v_invitee
    and status = 'pending' and expires_at <= now();
  insert into public.league_invites (league_id, inviter_id, invitee_id)
  values (p_league_id, auth.uid(), v_invitee) returning id into v_id;
  return v_id;
exception when unique_violation then raise exception 'That person already has a pending invitation.';
end;
$$;

create or replace function public.get_my_league_invites()
returns table (id uuid, league_id uuid, league_name text,
  inviter_username text, created_at timestamptz, expires_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select invite.id, invite.league_id, league.name, profile.username,
    invite.created_at, invite.expires_at
  from public.league_invites invite
  join public.leagues league on league.id = invite.league_id
  join public.profiles profile on profile.user_id = invite.inviter_id
  where invite.invitee_id = auth.uid() and invite.status = 'pending'
    and invite.expires_at > now()
  order by invite.created_at desc;
$$;

create or replace function public.respond_to_league_invite(p_invite_id uuid, p_accept boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_invite public.league_invites; v_team_id uuid;
begin
  select * into v_invite from public.league_invites where id = p_invite_id for update;
  if v_invite.id is null or v_invite.invitee_id is distinct from auth.uid()
     or v_invite.status <> 'pending' or v_invite.expires_at <= now() then
    raise exception 'Invitation is no longer available.';
  end if;
  if p_accept then v_team_id := public.join_league_from_invite(v_invite.league_id, auth.uid()); end if;
  update public.league_invites set status = case when p_accept then 'accepted' else 'declined' end,
    responded_at = now() where id = p_invite_id;
  return v_team_id;
end;
$$;

create or replace function public.cancel_league_invite(p_invite_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_league_id uuid;
begin
  select league_id into v_league_id from public.league_invites where id = p_invite_id;
  if not public.is_league_owner(v_league_id) then raise exception 'League owner access required.'; end if;
  update public.league_invites set status = 'cancelled', responded_at = now()
  where id = p_invite_id and status = 'pending';
end;
$$;

create table if not exists public.league_invite_links (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  token_hash text not null unique,
  created_by uuid not null references public.profiles(user_id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '14 days'),
  revoked_at timestamptz
);
create unique index if not exists league_invite_links_one_live_idx
  on public.league_invite_links (league_id) where revoked_at is null;
alter table public.league_invite_links enable row level security;
create policy "owners read invite link metadata" on public.league_invite_links
  for select to authenticated using (public.is_league_owner(league_id));
revoke all on public.league_invite_links from public, anon, authenticated;
grant select (id, league_id, created_by, created_at, expires_at, revoked_at)
  on public.league_invite_links to authenticated;

create or replace function public.regenerate_league_invite_link(p_league_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare v_token text;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  perform 1 from public.leagues where id = p_league_id for update;
  if (select status from public.leagues where id = p_league_id) <> 'setup' then
    raise exception 'Invitations are available before the draft starts.';
  end if;
  update public.league_invite_links set revoked_at = now()
  where league_id = p_league_id and revoked_at is null;
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.league_invite_links (league_id, token_hash, created_by)
  values (p_league_id, md5(v_token), auth.uid());
  return v_token;
end;
$$;

create or replace function public.revoke_league_invite_link(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  update public.league_invite_links set revoked_at = now()
  where league_id = p_league_id and revoked_at is null;
end;
$$;

create or replace function public.preview_league_invite_link(p_token text)
returns table (league_id uuid, league_name text, expires_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select league.id, league.name, link.expires_at
  from public.league_invite_links link
  join public.leagues league on league.id = link.league_id
  where char_length(coalesce(p_token, '')) = 64
    and link.token_hash = md5(p_token)
    and link.revoked_at is null and link.expires_at > now()
    and league.status = 'setup';
$$;

create or replace function public.join_league_with_link(p_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_league_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to join this league.'; end if;
  select preview.league_id into v_league_id
  from public.preview_league_invite_link(p_token) preview;
  if v_league_id is null then raise exception 'Invite link is invalid or expired.'; end if;
  perform public.join_league_from_invite(v_league_id, auth.uid());
  return v_league_id;
end;
$$;

create or replace function public.remove_league_member(p_league_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_team_id uuid;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  perform 1 from public.leagues where id = p_league_id for update;
  if (select status from public.leagues where id = p_league_id) <> 'setup' then
    raise exception 'Members can only be removed before the draft starts.';
  end if;
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = p_league_id and user_id = p_user_id and role = 'member';
  if v_team_id is null then raise exception 'Member not found.'; end if;
  delete from public.league_members where league_id = p_league_id and user_id = p_user_id;
  delete from public.fantasy_teams where id = v_team_id and league_id = p_league_id;
end;
$$;

create or replace function public.update_league_team_name(p_league_id uuid, p_team_name text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_team_id uuid;
begin
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = p_league_id and user_id = auth.uid() and status = 'active';
  if v_team_id is null then raise exception 'League membership required.'; end if;
  if char_length(trim(coalesce(p_team_name, ''))) > 80 then raise exception 'Team name must be 80 characters or fewer.'; end if;
  update public.fantasy_teams set team_name = nullif(trim(coalesce(p_team_name, '')), '')
  where id = v_team_id and league_id = p_league_id;
end;
$$;

create or replace function public.update_league_role_rates(p_league_id uuid, p_rates jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_rate jsonb; v_role_id uuid; v_points integer;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  if jsonb_typeof(p_rates) is distinct from 'array' then raise exception 'Rates must be a list.'; end if;
  for v_rate in select value from jsonb_array_elements(p_rates) loop
    if coalesce(v_rate->>'appearance_points', '') !~ '^[0-9]{1,2}$' then
      raise exception 'Rates must be whole numbers from 0 to 99.';
    end if;
    v_points := (v_rate->>'appearance_points')::integer;
    select id into v_role_id from public.roles where name = v_rate->>'name';
    if v_role_id is null then raise exception 'Unknown role.'; end if;
    insert into public.league_role_rates (league_id, role_id, appearance_points)
    values (p_league_id, v_role_id, v_points)
    on conflict (league_id, role_id) do update
      set appearance_points = excluded.appearance_points, updated_at = now();
  end loop;
end;
$$;

-- A new canonical cast role receives a default rate in every existing league.
create or replace function public.seed_new_role_for_leagues()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.league_role_rates (league_id, role_id, appearance_points)
  select league.id, new.id, new.appearance_points from public.leagues league
  on conflict (league_id, role_id) do nothing;
  return new;
end;
$$;
drop trigger if exists seed_new_role_for_leagues on public.roles;
create trigger seed_new_role_for_leagues after insert on public.roles
for each row execute function public.seed_new_role_for_leagues();
revoke all on function public.seed_new_role_for_leagues() from public, anon, authenticated;

create table if not exists public.league_draft_order (
  league_id uuid not null references public.leagues(id) on delete cascade,
  draft_position integer not null check (draft_position >= 1),
  fantasy_team_id uuid not null,
  primary key (league_id, draft_position),
  unique (league_id, fantasy_team_id),
  foreign key (league_id, fantasy_team_id)
    references public.fantasy_teams(league_id, id) on delete cascade
);
create table if not exists public.league_draft_picks (
  league_id uuid not null references public.leagues(id) on delete cascade,
  pick_number integer not null check (pick_number >= 1),
  round_number integer not null check (round_number >= 1),
  fantasy_team_id uuid not null,
  cast_member_id uuid not null references public.cast_members(id),
  picked_by uuid not null references public.profiles(user_id),
  picked_at timestamptz not null default now(),
  primary key (league_id, pick_number),
  unique (league_id, cast_member_id),
  foreign key (league_id, fantasy_team_id)
    references public.fantasy_teams(league_id, id)
);
alter table public.league_draft_order enable row level security;
alter table public.league_draft_picks enable row level security;
create policy "members read draft order" on public.league_draft_order
  for select to authenticated using (public.is_league_member(league_id));
create policy "members read draft picks" on public.league_draft_picks
  for select to authenticated using (public.is_league_member(league_id));
revoke all on public.league_draft_order, public.league_draft_picks from public, anon, authenticated;
grant select on public.league_draft_order, public.league_draft_picks to authenticated;

-- The original completion RPC still uses a unique (week_id, cast_member_id)
-- conflict target. A separate table preserves that legacy behavior while
-- giving each later league an independent, immutable roster checkpoint.
create table if not exists public.league_weekly_roster_snapshots (
  league_id uuid not null references public.leagues(id) on delete cascade,
  week_id uuid not null references public.weeks(id) on delete cascade,
  cast_member_id uuid not null references public.cast_members(id),
  fantasy_team_id uuid references public.fantasy_teams(id),
  cast_member_name text not null,
  cast_role text not null,
  appearance_points integer,
  manager_name text,
  team_name text,
  created_at timestamptz not null default now(),
  primary key (league_id, week_id, cast_member_id),
  foreign key (league_id, fantasy_team_id)
    references public.fantasy_teams(league_id, id)
);
create index if not exists league_weekly_snapshots_team_week_idx
  on public.league_weekly_roster_snapshots (league_id, fantasy_team_id, week_id);
alter table public.league_weekly_roster_snapshots enable row level security;
create policy "members read league week snapshots" on public.league_weekly_roster_snapshots
  for select to authenticated using (public.is_league_member(league_id));
revoke all on public.league_weekly_roster_snapshots from public, anon, authenticated;
grant select on public.league_weekly_roster_snapshots to authenticated;

create or replace function public.start_league_draft(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_league public.leagues; v_team_count integer;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.status <> 'setup' then raise exception 'The draft has already started.'; end if;
  select count(*) into v_team_count from public.league_members
  where league_id = p_league_id and status = 'active';
  if v_team_count < 2 then raise exception 'Invite at least one other manager before starting the draft.'; end if;
  if v_team_count * v_league.roster_size > (select count(*) from public.cast_members) then
    raise exception 'There are not enough cast members for this roster size.';
  end if;
  insert into public.league_draft_order (league_id, draft_position, fantasy_team_id)
  select p_league_id, row_number() over (order by random(), member.user_id),
    member.fantasy_team_id
  from public.league_members member
  where member.league_id = p_league_id and member.status = 'active';
  update public.league_invites set status = 'cancelled', responded_at = now()
  where league_id = p_league_id and status = 'pending';
  update public.league_invite_links set revoked_at = now()
  where league_id = p_league_id and revoked_at is null;
  update public.leagues set status = 'drafting', draft_started_at = now(), updated_at = now()
  where id = p_league_id;
end;
$$;

create or replace function public.claim_league_cast_member(
  p_league_id uuid, p_incoming_cast_member_id uuid,
  p_outgoing_cast_member_id uuid default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_league public.leagues;
  v_team_id uuid;
  v_team_count integer;
  v_pick_count integer;
  v_round integer;
  v_position integer;
  v_expected_team uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to claim cast.'; end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id() then
    raise exception 'Use the original league roster controls for this league.';
  end if;
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = p_league_id and user_id = auth.uid() and status = 'active';
  if v_team_id is null then raise exception 'League membership required.'; end if;
  if not exists (select 1 from public.cast_members where id = p_incoming_cast_member_id) then
    raise exception 'Cast member not found.';
  end if;
  if exists (select 1 from public.league_roster_assignments
             where league_id = p_league_id and cast_member_id = p_incoming_cast_member_id) then
    raise exception 'This cast member is already claimed.';
  end if;

  if v_league.status = 'drafting' then
    if p_outgoing_cast_member_id is not null then raise exception 'Draft picks do not release cast.'; end if;
    select count(*) into v_team_count from public.league_draft_order where league_id = p_league_id;
    select count(*) into v_pick_count from public.league_draft_picks where league_id = p_league_id;
    v_round := v_pick_count / v_team_count + 1;
    if v_round > v_league.roster_size then raise exception 'The draft is complete.'; end if;
    v_position := (v_pick_count % v_team_count) + 1;
    if v_round % 2 = 0 then v_position := v_team_count - v_position + 1; end if;
    select fantasy_team_id into v_expected_team from public.league_draft_order
    where league_id = p_league_id and draft_position = v_position;
    if v_expected_team is distinct from v_team_id then raise exception 'It is not your turn to draft.'; end if;
    insert into public.league_roster_assignments (league_id, cast_member_id, fantasy_team_id)
    values (p_league_id, p_incoming_cast_member_id, v_team_id);
    insert into public.league_draft_picks
      (league_id, pick_number, round_number, fantasy_team_id, cast_member_id, picked_by)
    values (p_league_id, v_pick_count + 1, v_round, v_team_id,
      p_incoming_cast_member_id, auth.uid());
    if v_pick_count + 1 = v_team_count * v_league.roster_size then
      update public.leagues set status = 'active', draft_completed_at = now(),
        scoring_starts_after_week = coalesce((select max(number) from public.weeks where is_complete), 0),
        updated_at = now() where id = p_league_id;
    end if;
  elsif v_league.status = 'active' then
    if p_outgoing_cast_member_id is null then raise exception 'Choose a cast member to release.'; end if;
    if p_incoming_cast_member_id = p_outgoing_cast_member_id then raise exception 'Choose different cast members.'; end if;
    if not exists (select 1 from public.league_roster_assignments
      where league_id = p_league_id and fantasy_team_id = v_team_id
        and cast_member_id = p_outgoing_cast_member_id) then
      raise exception 'The outgoing cast member is not on your team.';
    end if;
    if exists (select 1 from public.league_trade_offers offer
      where offer.league_id = p_league_id and p_outgoing_cast_member_id in
        (offer.initiator_cast_member_id, offer.counterparty_cast_member_id)) then
      raise exception 'This cast member has an active trade offer.';
    end if;
    delete from public.league_roster_assignments
    where league_id = p_league_id and cast_member_id = p_outgoing_cast_member_id;
    insert into public.league_roster_assignments (league_id, cast_member_id, fantasy_team_id)
    values (p_league_id, p_incoming_cast_member_id, v_team_id);
  else
    raise exception 'Claims open when the draft starts.';
  end if;
end;
$$;

-- The Score Desk keeps one canonical show schedule. Every active league gets
-- its own immutable roster checkpoint when a new airing is completed.
create or replace function public.snapshot_other_leagues_on_week_completion()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.is_complete and not old.is_complete then
    insert into public.league_weekly_roster_snapshots
      (league_id, week_id, cast_member_id, fantasy_team_id,
       cast_member_name, cast_role, appearance_points, manager_name, team_name)
    select league.id, new.id, cast_member.id, assignment.fantasy_team_id,
      cast_member.name,
      case
        when cast_member.eliminated_week_id = new.id and cast_member.role = 'Eliminated Star' then 'Star'
        when cast_member.eliminated_week_id = new.id and cast_member.role = 'Eliminated Pro' then 'Pro'
        else cast_member.role
      end,
      case
        when cast_member.role = 'Surprise' then cast_member.custom_appearance_points
        else (select rate.appearance_points
          from public.league_role_rates rate
          join public.roles role on role.id = rate.role_id
          where rate.league_id = league.id
            and role.name = case
              when cast_member.is_hough then 'Hough'
              when cast_member.eliminated_week_id = new.id and cast_member.role = 'Eliminated Star' then 'Star'
              when cast_member.eliminated_week_id = new.id and cast_member.role = 'Eliminated Pro' then 'Pro'
              else cast_member.role end)
      end,
      team.manager_name, team.team_name
    from public.leagues league
    cross join public.cast_members cast_member
    left join public.league_roster_assignments assignment
      on assignment.league_id = league.id and assignment.cast_member_id = cast_member.id
    left join public.fantasy_teams team on team.id = assignment.fantasy_team_id
    where league.id <> public.default_fantasy_league_id()
      and league.status = 'active'
      and new.number > league.scoring_starts_after_week
    on conflict (league_id, week_id, cast_member_id) do nothing;
  end if;
  return new;
end;
$$;
drop trigger if exists snapshot_other_leagues_on_week_completion on public.weeks;
create trigger snapshot_other_leagues_on_week_completion
after update of is_complete on public.weeks for each row
execute function public.snapshot_other_leagues_on_week_completion();

-- Secondary leagues have private one-for-one trades backed by their own
-- assignment table. The original trade RPCs remain tied to the original league.
create table if not exists public.league_trade_offers (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  initiator_team_id uuid not null references public.fantasy_teams(id),
  counterparty_team_id uuid not null references public.fantasy_teams(id),
  initiator_cast_member_id uuid not null references public.cast_members(id),
  counterparty_cast_member_id uuid not null references public.cast_members(id),
  awaiting_team_id uuid not null references public.fantasy_teams(id),
  status text not null default 'pending' check (status in ('pending','countered')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '48 hours'),
  check (initiator_team_id <> counterparty_team_id),
  check (initiator_cast_member_id <> counterparty_cast_member_id),
  check (awaiting_team_id in (initiator_team_id, counterparty_team_id)),
  foreign key (league_id, initiator_team_id) references public.fantasy_teams(league_id, id),
  foreign key (league_id, counterparty_team_id) references public.fantasy_teams(league_id, id)
);
create index if not exists league_trade_offers_team_idx
  on public.league_trade_offers (league_id, awaiting_team_id, updated_at desc);
create table if not exists public.league_trade_events (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references public.leagues(id) on delete cascade,
  trade_id uuid not null,
  event_type text not null check (event_type in ('countered','accepted','denied','cancelled','expired','invalidated')),
  initiator_team_id uuid not null,
  counterparty_team_id uuid not null,
  initiator_cast_member_name text not null,
  counterparty_cast_member_name text not null,
  notification_team_id uuid,
  dismissed_at timestamptz,
  event_at timestamptz not null default now()
);
create index if not exists league_trade_events_teams_idx
  on public.league_trade_events (league_id, event_at desc);
alter table public.league_trade_offers enable row level security;
alter table public.league_trade_events enable row level security;
create policy "trade participants read offers" on public.league_trade_offers
  for select to authenticated using (
    exists (select 1 from public.league_members member
      where member.league_id = league_trade_offers.league_id
        and member.user_id = auth.uid() and member.status = 'active'
        and member.fantasy_team_id in (initiator_team_id, counterparty_team_id))
  );
create policy "trade participants read events" on public.league_trade_events
  for select to authenticated using (
    exists (select 1 from public.league_members member
      where member.league_id = league_trade_events.league_id
        and member.user_id = auth.uid() and member.status = 'active'
        and member.fantasy_team_id in (initiator_team_id, counterparty_team_id))
  );
revoke all on public.league_trade_offers, public.league_trade_events from public, anon, authenticated;
grant select on public.league_trade_offers, public.league_trade_events to authenticated;

create or replace function public.record_league_trade_event(
  p_offer public.league_trade_offers, p_event_type text, p_notify_team_id uuid default null
)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.league_trade_events
    (league_id, trade_id, event_type, initiator_team_id, counterparty_team_id,
     initiator_cast_member_name, counterparty_cast_member_name, notification_team_id)
  values (p_offer.league_id, p_offer.id, p_event_type,
    p_offer.initiator_team_id, p_offer.counterparty_team_id,
    coalesce((select name from public.cast_members where id = p_offer.initiator_cast_member_id), 'Former cast member'),
    coalesce((select name from public.cast_members where id = p_offer.counterparty_cast_member_id), 'Former cast member'),
    p_notify_team_id);
end;
$$;
revoke all on function public.record_league_trade_event(public.league_trade_offers,text,uuid)
  from public, anon, authenticated;

create or replace function public.expire_league_trade_offers(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_offer public.league_trade_offers;
begin
  for v_offer in select * from public.league_trade_offers
    where league_id = p_league_id and expires_at <= now() for update
  loop
    perform public.record_league_trade_event(v_offer, 'expired');
    delete from public.league_trade_offers where id = v_offer.id;
  end loop;
end;
$$;
revoke all on function public.expire_league_trade_offers(uuid) from public, anon, authenticated;

create or replace function public.get_my_league_trades(p_league_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_team_id uuid; v_offers jsonb; v_events jsonb; v_notifications jsonb;
begin
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = p_league_id and user_id = auth.uid() and status = 'active';
  if v_team_id is null then raise exception 'League membership required.'; end if;
  perform public.expire_league_trade_offers(p_league_id);
  select coalesce(jsonb_agg(to_jsonb(offer) order by offer.updated_at desc), '[]'::jsonb)
    into v_offers from public.league_trade_offers offer
    where offer.league_id = p_league_id
      and v_team_id in (offer.initiator_team_id, offer.counterparty_team_id);
  select coalesce(jsonb_agg(to_jsonb(event) order by event.event_at desc), '[]'::jsonb)
    into v_events from public.league_trade_events event
    where event.league_id = p_league_id
      and v_team_id in (event.initiator_team_id, event.counterparty_team_id)
      and (event.notification_team_id is distinct from v_team_id or event.dismissed_at is not null);
  select coalesce(jsonb_agg(to_jsonb(event) order by event.event_at desc), '[]'::jsonb)
    into v_notifications from public.league_trade_events event
    where event.league_id = p_league_id and event.notification_team_id = v_team_id
      and event.dismissed_at is null;
  return jsonb_build_object('offers', v_offers, 'history', v_events, 'notifications', v_notifications);
end;
$$;

create or replace function public.request_league_trade(
  p_league_id uuid, p_my_cast_member_id uuid, p_requested_cast_member_id uuid
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_team_id uuid; v_other_team_id uuid; v_id uuid;
begin
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = p_league_id and user_id = auth.uid() and status = 'active';
  if v_team_id is null or (select status from public.leagues where id = p_league_id) <> 'active' then
    raise exception 'Trading is available after your league draft is complete.';
  end if;
  perform 1 from public.leagues where id = p_league_id for update;
  perform public.expire_league_trade_offers(p_league_id);
  if p_my_cast_member_id = p_requested_cast_member_id then raise exception 'Choose different cast members.'; end if;
  if not exists (select 1 from public.league_roster_assignments where league_id = p_league_id
    and cast_member_id = p_my_cast_member_id and fantasy_team_id = v_team_id) then
    raise exception 'Offered cast member is no longer on your team.';
  end if;
  select fantasy_team_id into v_other_team_id from public.league_roster_assignments
  where league_id = p_league_id and cast_member_id = p_requested_cast_member_id;
  if v_other_team_id is null or v_other_team_id = v_team_id then
    raise exception 'Choose a cast member from another team.';
  end if;
  if exists (select 1 from public.league_trade_offers offer where offer.league_id = p_league_id
    and (p_my_cast_member_id in (offer.initiator_cast_member_id, offer.counterparty_cast_member_id)
      or p_requested_cast_member_id in (offer.initiator_cast_member_id, offer.counterparty_cast_member_id))) then
    raise exception 'One of these cast members has an active offer.';
  end if;
  insert into public.league_trade_offers
    (league_id, initiator_team_id, counterparty_team_id,
     initiator_cast_member_id, counterparty_cast_member_id, awaiting_team_id)
  values (p_league_id, v_team_id, v_other_team_id,
    p_my_cast_member_id, p_requested_cast_member_id, v_other_team_id)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.respond_to_league_trade(
  p_offer_id uuid, p_action text, p_replace_side text default null,
  p_replacement_cast_member_id uuid default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare v_offer public.league_trade_offers; v_other_offer public.league_trade_offers;
  v_my_team_id uuid; v_sender_team_id uuid;
  v_replacement_team_id uuid; v_expected_team_id uuid;
  v_accepted_league_id uuid; v_accepted_initiator_cast_id uuid;
  v_accepted_counterparty_cast_id uuid;
begin
  select * into v_offer from public.league_trade_offers where id = p_offer_id;
  if v_offer.id is null then raise exception 'Trade offer is no longer available.'; end if;
  perform 1 from public.leagues where id = v_offer.league_id for update;
  perform public.expire_league_trade_offers(v_offer.league_id);
  select * into v_offer from public.league_trade_offers where id = p_offer_id for update;
  if v_offer.id is null then raise exception 'Trade offer has expired.'; end if;
  select fantasy_team_id into v_my_team_id from public.league_members
  where league_id = v_offer.league_id and user_id = auth.uid() and status = 'active';
  if v_my_team_id is null then raise exception 'League membership required.'; end if;
  v_sender_team_id := case when v_offer.awaiting_team_id = v_offer.initiator_team_id
    then v_offer.counterparty_team_id else v_offer.initiator_team_id end;

  if p_action = 'cancel' then
    if v_my_team_id <> v_sender_team_id then raise exception 'Only the sender can cancel this offer.'; end if;
    perform public.record_league_trade_event(v_offer, 'cancelled');
    delete from public.league_trade_offers where id = p_offer_id;
    return;
  end if;
  if v_my_team_id <> v_offer.awaiting_team_id then raise exception 'This offer is awaiting the other manager.'; end if;
  if p_action = 'deny' then
    perform public.record_league_trade_event(v_offer, 'denied', v_sender_team_id);
    delete from public.league_trade_offers where id = p_offer_id;
  elsif p_action = 'accept' then
    if not exists (select 1 from public.league_roster_assignments where league_id = v_offer.league_id
      and cast_member_id = v_offer.initiator_cast_member_id and fantasy_team_id = v_offer.initiator_team_id)
      or not exists (select 1 from public.league_roster_assignments where league_id = v_offer.league_id
      and cast_member_id = v_offer.counterparty_cast_member_id and fantasy_team_id = v_offer.counterparty_team_id) then
      raise exception 'The offer no longer matches the current rosters.';
    end if;
    update public.league_roster_assignments
    set fantasy_team_id = case
      when cast_member_id = v_offer.initiator_cast_member_id then v_offer.counterparty_team_id
      else v_offer.initiator_team_id end
    where league_id = v_offer.league_id
      and cast_member_id in (v_offer.initiator_cast_member_id, v_offer.counterparty_cast_member_id);
    perform public.record_league_trade_event(v_offer, 'accepted', v_sender_team_id);
    v_accepted_league_id := v_offer.league_id;
    v_accepted_initiator_cast_id := v_offer.initiator_cast_member_id;
    v_accepted_counterparty_cast_id := v_offer.counterparty_cast_member_id;
    delete from public.league_trade_offers where id = p_offer_id;
    -- Other offers involving either newly traded cast member can no longer be honored.
    for v_other_offer in select * from public.league_trade_offers offer
      where offer.league_id = v_accepted_league_id
        and (offer.initiator_cast_member_id in (v_accepted_initiator_cast_id, v_accepted_counterparty_cast_id)
          or offer.counterparty_cast_member_id in (v_accepted_initiator_cast_id, v_accepted_counterparty_cast_id))
      for update
    loop
      perform public.record_league_trade_event(v_other_offer, 'invalidated');
      delete from public.league_trade_offers where id = v_other_offer.id;
    end loop;
  elsif p_action = 'counter' then
    if p_replace_side not in ('initiator', 'counterparty') or p_replacement_cast_member_id is null then
      raise exception 'Replace exactly one side of the offer.';
    end if;
    v_expected_team_id := case when p_replace_side = 'initiator'
      then v_offer.initiator_team_id else v_offer.counterparty_team_id end;
    select fantasy_team_id into v_replacement_team_id from public.league_roster_assignments
    where league_id = v_offer.league_id and cast_member_id = p_replacement_cast_member_id;
    if v_replacement_team_id is distinct from v_expected_team_id
      or p_replacement_cast_member_id in (v_offer.initiator_cast_member_id, v_offer.counterparty_cast_member_id) then
      raise exception 'Choose another cast member on the same team.';
    end if;
    if exists (select 1 from public.league_trade_offers offer
      where offer.league_id = v_offer.league_id and offer.id <> v_offer.id
        and p_replacement_cast_member_id in (offer.initiator_cast_member_id, offer.counterparty_cast_member_id)) then
      raise exception 'That cast member has another active offer.';
    end if;
    perform public.record_league_trade_event(v_offer, 'countered');
    update public.league_trade_offers set
      initiator_cast_member_id = case when p_replace_side = 'initiator'
        then p_replacement_cast_member_id else initiator_cast_member_id end,
      counterparty_cast_member_id = case when p_replace_side = 'counterparty'
        then p_replacement_cast_member_id else counterparty_cast_member_id end,
      awaiting_team_id = v_sender_team_id, status = 'countered',
      expires_at = now() + interval '48 hours', updated_at = now()
    where id = p_offer_id;
  else
    raise exception 'Invalid trade action.';
  end if;
end;
$$;

create or replace function public.dismiss_league_trade_result(p_event_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_event public.league_trade_events; v_team_id uuid;
begin
  select * into v_event from public.league_trade_events where id = p_event_id for update;
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = v_event.league_id and user_id = auth.uid() and status = 'active';
  if v_event.id is null or v_event.notification_team_id is distinct from v_team_id
    or v_event.dismissed_at is not null then raise exception 'Trade result is unavailable.'; end if;
  update public.league_trade_events set dismissed_at = now() where id = p_event_id;
end;
$$;

revoke all on function public.get_my_league_trades(uuid), public.request_league_trade(uuid,uuid,uuid),
  public.respond_to_league_trade(uuid,text,text,uuid), public.dismiss_league_trade_result(uuid)
  from public, anon;
grant execute on function public.get_my_league_trades(uuid), public.request_league_trade(uuid,uuid,uuid),
  public.respond_to_league_trade(uuid,text,text,uuid), public.dismiss_league_trade_result(uuid)
  to authenticated;

-- Default-league swap controls must not take a team ID from a different league.
create or replace function public.swap_available_cast_member_into_team(
  p_team_id uuid, p_incoming_cast_member_id uuid, p_outgoing_cast_member_id uuid
)
returns void language plpgsql security definer set search_path = '' as $$
declare v_my_team_id uuid;
begin
  select fantasy_team_id into v_my_team_id from public.league_members
  where league_id = public.default_fantasy_league_id() and user_id = auth.uid();
  if v_my_team_id is distinct from p_team_id then raise exception 'You may only claim for your own team.'; end if;
  if not exists (select 1 from public.fantasy_teams
    where id = p_team_id and league_id = public.default_fantasy_league_id()) then
    raise exception 'Fantasy team not found.';
  end if;
  if p_incoming_cast_member_id = p_outgoing_cast_member_id then raise exception 'Choose different cast members.'; end if;
  perform 1 from public.cast_members
  where id in (p_incoming_cast_member_id, p_outgoing_cast_member_id) order by id for update;
  if (select fantasy_team_id from public.cast_members where id = p_incoming_cast_member_id) is not null then
    raise exception 'Incoming cast is no longer available.';
  end if;
  if (select fantasy_team_id from public.cast_members where id = p_outgoing_cast_member_id) is distinct from p_team_id then
    raise exception 'Outgoing cast is no longer on your team.';
  end if;
  perform public.expire_trade_offers_locked();
  if exists (select 1 from public.trade_offers
    where league_id = public.default_fantasy_league_id()
      and (initiator_cast_member_id = p_outgoing_cast_member_id
        or counterparty_cast_member_id = p_outgoing_cast_member_id)) then
    raise exception 'This cast member has an active trade offer.';
  end if;
  update public.cast_members set fantasy_team_id = case
    when id = p_incoming_cast_member_id then p_team_id else null end
  where id in (p_incoming_cast_member_id, p_outgoing_cast_member_id);
end;
$$;

revoke all on function public.invite_username(uuid,text), public.get_my_league_invites(),
  public.respond_to_league_invite(uuid,boolean), public.cancel_league_invite(uuid),
  public.regenerate_league_invite_link(uuid), public.revoke_league_invite_link(uuid),
  public.join_league_with_link(text),
  public.remove_league_member(uuid,uuid), public.update_league_team_name(uuid,text),
  public.update_league_role_rates(uuid,jsonb), public.start_league_draft(uuid),
  public.claim_league_cast_member(uuid,uuid,uuid) from public, anon;
grant execute on function public.invite_username(uuid,text), public.get_my_league_invites(),
  public.respond_to_league_invite(uuid,boolean), public.cancel_league_invite(uuid),
  public.regenerate_league_invite_link(uuid), public.revoke_league_invite_link(uuid),
  public.join_league_with_link(text),
  public.remove_league_member(uuid,uuid), public.update_league_team_name(uuid,text),
  public.update_league_role_rates(uuid,jsonb), public.start_league_draft(uuid),
  public.claim_league_cast_member(uuid,uuid,uuid) to authenticated;
revoke all on function public.preview_league_invite_link(text) from public;
grant execute on function public.preview_league_invite_link(text) to anon, authenticated;
revoke all on function public.snapshot_other_leagues_on_week_completion() from public, anon, authenticated;
revoke all on function public.swap_available_cast_member_into_team(uuid,uuid,uuid) from public, anon;
grant execute on function public.swap_available_cast_member_into_team(uuid,uuid,uuid) to authenticated;

commit;
notify pgrst, 'reload schema';
