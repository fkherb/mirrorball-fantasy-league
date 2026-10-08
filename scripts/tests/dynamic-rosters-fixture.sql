-- TEST ONLY. Install only in the disposable container named by the test runner.
create schema if not exists auth;
do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
end $$;
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.user_id',true),'')::uuid $$;
create table public.leagues(id uuid primary key,status text,roster_size integer,draft_cast_roles jsonb default '{}');
create table public.fantasy_teams(id uuid primary key,league_id uuid references public.leagues on delete cascade);
create table public.league_members(league_id uuid,user_id uuid,fantasy_team_id uuid,status text default 'active');
create table public.league_draft_order(league_id uuid,fantasy_team_id uuid);
create table public.cast_members(id uuid primary key default gen_random_uuid(),role text);
create table public.league_roster_assignments(league_id uuid,cast_member_id uuid references public.cast_members,fantasy_team_id uuid,assigned_at timestamptz default now(),primary key(league_id,cast_member_id));
create table public.league_trade_offers(id uuid primary key default gen_random_uuid(),league_id uuid,initiator_team_id uuid,counterparty_team_id uuid,initiator_cast_member_id uuid,counterparty_cast_member_id uuid);
create function public.default_fantasy_league_id() returns uuid language sql as $$ select '00000000-0000-4000-8000-000000000001'::uuid $$;
create function public.is_league_member(p uuid) returns boolean language sql as $$ select exists(select 1 from public.league_members where league_id=p and user_id=auth.uid() and status='active') $$;
create function public.league_trade_airing_locked() returns boolean language sql as $$ select coalesce(current_setting('test.airing_locked',true),'')='on' $$;
create function public.expire_league_trade_offers(p uuid) returns void language sql as $$ select $$;
create function public.league_cast_category(p text) returns text language sql as $$ select case when p in ('Pro','Star') then p else 'Bonus' end $$;
create function public.league_draft_role(p uuid,c uuid) returns text language sql stable as $$ select case when l.status='drafting' then l.draft_cast_roles->>c::text else m.role end from public.leagues l cross join public.cast_members m where l.id=p and m.id=c $$;
create function public.league_category_limit(p_league_id uuid,p_role text) returns integer language sql as $$ select count(*)::integer/4 from public.cast_members where role=p_role $$;
create function public.league_flex_allowance(p_league_id uuid) returns integer language sql as $$
 select case when l.roster_size>public.league_category_limit(l.id,'Pro')+public.league_category_limit(l.id,'Star')+(select count(*)::integer/4 from public.cast_members where role not in ('Pro','Star')) then 1 else 0 end from public.leagues l where id=p_league_id $$;
create function public.league_bonus_draft_limit(p_league_id uuid) returns integer language sql as $$
 select roster_size-public.league_category_limit(id,'Pro')-public.league_category_limit(id,'Star')-public.league_flex_allowance(id) from public.leagues where id=p_league_id $$;
create function public.capture_league_draft_cast_roles() returns trigger language plpgsql as $$ begin return new; end $$;
create trigger aaa_capture_league_draft_cast_roles before update of status on public.leagues for each row execute function public.capture_league_draft_cast_roles();
create function public.check_balanced_draft_capacity() returns trigger language plpgsql as $$ begin return new; end $$;
create trigger check_balanced_draft_capacity before update of status on public.leagues for each row execute function public.check_balanced_draft_capacity();
create function public.check_secondary_league_trade_role_limits() returns trigger language plpgsql as $$ begin return new; end $$;
create trigger check_secondary_league_trade_role_limits before insert or update of initiator_cast_member_id,counterparty_cast_member_id on public.league_trade_offers for each row execute function public.check_secondary_league_trade_role_limits();
-- A minimal previous path: tests delegate draft/default behavior through it,
-- while the untouched production path retains its real auth/clock/history.
create function public.claim_league_cast_member(p_league_id uuid,p_incoming_cast_member_id uuid,p_outgoing_cast_member_id uuid default null) returns void language plpgsql as $$
declare t uuid;
begin
  select fantasy_team_id into t from public.league_members where league_id=p_league_id and user_id=auth.uid();
  if p_outgoing_cast_member_id is null then insert into public.league_roster_assignments(league_id,cast_member_id,fantasy_team_id) values(p_league_id,p_incoming_cast_member_id,t);
  else update public.league_roster_assignments set cast_member_id=p_incoming_cast_member_id where league_id=p_league_id and cast_member_id=p_outgoing_cast_member_id; end if;
end $$;
