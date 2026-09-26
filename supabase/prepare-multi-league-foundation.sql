-- Mirrorball Fantasy League: additive multi-league database foundation.
--
-- This migration creates and seeds ONLY the existing league. It does not add
-- league creation to the website and does not change the current user flow.
-- Run after harden-data-integrity-and-manager-inputs.sql and before
-- add-trade-result-notifications.sql.

begin;

create table if not exists public.leagues (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null check (char_length(trim(name)) between 1 and 80),
  created_by uuid references auth.users(id) on delete set null,
  status text not null default 'active' check (status in ('active', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.leagues (id, slug, name, created_by)
values (
  '00000000-0000-4000-8000-000000000001'::uuid,
  'dwts-fantasy-league',
  coalesce((select league_name from public.league_settings where id = 1), 'DWTS Fantasy League'),
  (select user_id from public.platform_admins order by created_at limit 1)
)
on conflict (slug) do nothing;

create or replace function public.default_fantasy_league_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from public.leagues where slug = 'dwts-fantasy-league' limit 1;
$$;

revoke all on function public.default_fantasy_league_id() from public, anon, authenticated;

create or replace function public.apply_default_league_scope()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.league_id is null then
    new.league_id := public.default_fantasy_league_id();
  end if;
  if new.league_id is null then raise exception 'The default fantasy league is missing.'; end if;
  return new;
end;
$$;

revoke all on function public.apply_default_league_scope() from public, anon, authenticated;

-- Scope every current league-owned record to the seeded league. The default
-- triggers preserve compatibility with the existing single-league RPCs.
alter table public.fantasy_teams add column if not exists league_id uuid references public.leagues(id);
update public.fantasy_teams set league_id = public.default_fantasy_league_id() where league_id is null;
alter table public.fantasy_teams alter column league_id set not null;
drop trigger if exists fantasy_teams_default_league_scope on public.fantasy_teams;
create trigger fantasy_teams_default_league_scope
before insert on public.fantasy_teams
for each row execute function public.apply_default_league_scope();

alter table public.fantasy_teams drop constraint if exists fantasy_teams_manager_name_key;
create unique index if not exists fantasy_teams_league_manager_name_key
  on public.fantasy_teams (league_id, manager_name);
create unique index if not exists fantasy_teams_league_id_id_key
  on public.fantasy_teams (league_id, id);

alter table public.league_members add column if not exists league_id uuid references public.leagues(id);
update public.league_members set league_id = public.default_fantasy_league_id() where league_id is null;
alter table public.league_members alter column league_id set not null;
drop trigger if exists league_members_default_league_scope on public.league_members;
create trigger league_members_default_league_scope
before insert on public.league_members
for each row execute function public.apply_default_league_scope();

alter table public.league_members drop constraint if exists league_members_pkey;
alter table public.league_members add constraint league_members_pkey primary key (league_id, user_id);
create index if not exists league_members_user_id_idx on public.league_members (user_id);

alter table public.league_settings add column if not exists league_id uuid references public.leagues(id);
update public.league_settings set league_id = public.default_fantasy_league_id() where league_id is null;
alter table public.league_settings alter column league_id set not null;
create unique index if not exists league_settings_league_id_key on public.league_settings (league_id);
drop trigger if exists league_settings_default_league_scope on public.league_settings;
create trigger league_settings_default_league_scope
before insert on public.league_settings
for each row execute function public.apply_default_league_scope();

create or replace function public.sync_league_settings_name()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.leagues
  set name = new.league_name, updated_at = now()
  where id = new.league_id;
  return new;
end;
$$;

revoke all on function public.sync_league_settings_name() from public, anon, authenticated;
drop trigger if exists sync_league_settings_name on public.league_settings;
create trigger sync_league_settings_name
after insert or update of league_name on public.league_settings
for each row execute function public.sync_league_settings_name();

alter table public.weekly_roster_snapshots add column if not exists league_id uuid references public.leagues(id);
update public.weekly_roster_snapshots set league_id = public.default_fantasy_league_id() where league_id is null;
alter table public.weekly_roster_snapshots alter column league_id set not null;
drop trigger if exists weekly_snapshots_default_league_scope on public.weekly_roster_snapshots;
create trigger weekly_snapshots_default_league_scope
before insert on public.weekly_roster_snapshots
for each row execute function public.apply_default_league_scope();

alter table public.weekly_roster_snapshots drop constraint if exists weekly_roster_snapshots_pkey;
alter table public.weekly_roster_snapshots
  add constraint weekly_roster_snapshots_pkey primary key (league_id, week_id, cast_member_id);
-- The current completion RPC still names the legacy conflict target. Keep it
-- unique until that RPC is made league-aware in the switching phase.
create unique index if not exists weekly_roster_snapshots_legacy_week_cast_key
  on public.weekly_roster_snapshots (week_id, cast_member_id);

create or replace function public.apply_trade_offer_league_scope()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_initiator_league_id uuid;
  v_counterparty_league_id uuid;
begin
  select league_id into v_initiator_league_id from public.fantasy_teams where id = new.initiator_team_id;
  select league_id into v_counterparty_league_id from public.fantasy_teams where id = new.counterparty_team_id;
  if v_initiator_league_id is null or v_counterparty_league_id is null then
    raise exception 'Both fantasy teams must belong to a league.';
  end if;
  if v_initiator_league_id is distinct from v_counterparty_league_id then
    raise exception 'Trades cannot cross fantasy leagues.';
  end if;
  new.league_id := v_initiator_league_id;
  return new;
end;
$$;

revoke all on function public.apply_trade_offer_league_scope() from public, anon, authenticated;

alter table public.trade_offers add column if not exists league_id uuid references public.leagues(id);
update public.trade_offers as offer
set league_id = team.league_id
from public.fantasy_teams as team
where team.id = offer.initiator_team_id and offer.league_id is null;
alter table public.trade_offers alter column league_id set not null;
drop trigger if exists trade_offers_league_scope on public.trade_offers;
create trigger trade_offers_league_scope
before insert or update of initiator_team_id, counterparty_team_id on public.trade_offers
for each row execute function public.apply_trade_offer_league_scope();
create index if not exists trade_offers_league_updated_idx
  on public.trade_offers (league_id, updated_at desc);

create or replace function public.apply_trade_history_league_scope()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_history_league_id uuid;
begin
  if new.league_id is null then
    select league_id into v_history_league_id
    from public.fantasy_teams
    where id = coalesce(new.initiator_team_id, new.counterparty_team_id);
    new.league_id := v_history_league_id;
  end if;
  if new.league_id is null then new.league_id := public.default_fantasy_league_id(); end if;
  return new;
end;
$$;

revoke all on function public.apply_trade_history_league_scope() from public, anon, authenticated;

alter table public.trade_history add column if not exists league_id uuid references public.leagues(id);
update public.trade_history as history
set league_id = coalesce(
  (select team.league_id from public.fantasy_teams as team where team.id = history.initiator_team_id),
  (select team.league_id from public.fantasy_teams as team where team.id = history.counterparty_team_id),
  public.default_fantasy_league_id()
)
where history.league_id is null;
alter table public.trade_history alter column league_id set not null;
drop trigger if exists trade_history_league_scope on public.trade_history;
create trigger trade_history_league_scope
before insert on public.trade_history
for each row execute function public.apply_trade_history_league_scope();
create index if not exists trade_history_league_event_idx
  on public.trade_history (league_id, event_at desc);

-- League-scoped roster ownership is mirrored from the legacy cast column while
-- the current frontend remains single-league. Future league reads will move to
-- this table before cast_members.fantasy_team_id is retired.
create table if not exists public.league_roster_assignments (
  league_id uuid not null references public.leagues(id) on delete cascade,
  cast_member_id uuid not null references public.cast_members(id) on delete cascade,
  fantasy_team_id uuid not null references public.fantasy_teams(id) on delete cascade,
  assigned_at timestamptz not null default now(),
  primary key (league_id, cast_member_id),
  foreign key (league_id, fantasy_team_id)
    references public.fantasy_teams(league_id, id) on delete cascade
);

insert into public.league_roster_assignments (league_id, cast_member_id, fantasy_team_id)
select team.league_id, cast_member.id, cast_member.fantasy_team_id
from public.cast_members as cast_member
join public.fantasy_teams as team on team.id = cast_member.fantasy_team_id
where cast_member.fantasy_team_id is not null
on conflict (league_id, cast_member_id) do update
set fantasy_team_id = excluded.fantasy_team_id;

create or replace function public.sync_default_league_roster_assignment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_default_league_id uuid := public.default_fantasy_league_id();
  v_team_league_id uuid;
begin
  delete from public.league_roster_assignments
  where league_id = v_default_league_id and cast_member_id = new.id;

  if new.fantasy_team_id is not null then
    select league_id into v_team_league_id from public.fantasy_teams where id = new.fantasy_team_id;
    if v_team_league_id is distinct from v_default_league_id then
      raise exception 'The legacy roster field may only represent the default league.';
    end if;
    insert into public.league_roster_assignments (league_id, cast_member_id, fantasy_team_id)
    values (v_default_league_id, new.id, new.fantasy_team_id);
  end if;
  return new;
end;
$$;

revoke all on function public.sync_default_league_roster_assignment() from public, anon, authenticated;
drop trigger if exists sync_default_league_roster_assignment on public.cast_members;
create trigger sync_default_league_roster_assignment
after insert or update of fantasy_team_id on public.cast_members
for each row execute function public.sync_default_league_roster_assignment();

-- Role definitions stay canonical; each league receives its own configurable
-- rate row. Existing rate edits continue to mirror into the seeded league.
create table if not exists public.league_role_rates (
  league_id uuid not null references public.leagues(id) on delete cascade,
  role_id uuid not null references public.roles(id) on delete cascade,
  appearance_points integer check (appearance_points between 0 and 99),
  updated_at timestamptz not null default now(),
  primary key (league_id, role_id)
);

insert into public.league_role_rates (league_id, role_id, appearance_points)
select public.default_fantasy_league_id(), role.id, role.appearance_points
from public.roles as role
on conflict (league_id, role_id) do update
set appearance_points = excluded.appearance_points, updated_at = now();

create or replace function public.sync_default_league_role_rate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.league_role_rates (league_id, role_id, appearance_points, updated_at)
  values (public.default_fantasy_league_id(), new.id, new.appearance_points, now())
  on conflict (league_id, role_id) do update
  set appearance_points = excluded.appearance_points, updated_at = now();
  return new;
end;
$$;

revoke all on function public.sync_default_league_role_rate() from public, anon, authenticated;
drop trigger if exists sync_default_league_role_rate on public.roles;
create trigger sync_default_league_role_rate
after insert or update of appearance_points on public.roles
for each row execute function public.sync_default_league_role_rate();

alter table public.leagues enable row level security;
alter table public.league_roster_assignments enable row level security;
alter table public.league_role_rates enable row level security;

drop policy if exists "public reads active leagues" on public.leagues;
create policy "public reads active leagues" on public.leagues
for select to anon, authenticated using (status = 'active');
drop policy if exists "public reads league roster assignments" on public.league_roster_assignments;
create policy "public reads league roster assignments" on public.league_roster_assignments
for select to anon, authenticated using (true);
drop policy if exists "public reads league role rates" on public.league_role_rates;
create policy "public reads league role rates" on public.league_role_rates
for select to anon, authenticated using (true);

grant select on public.leagues, public.league_roster_assignments, public.league_role_rates to anon, authenticated;
revoke insert, update, delete on public.leagues, public.league_roster_assignments, public.league_role_rates from anon, authenticated;

commit;

notify pgrst, 'reload schema';
