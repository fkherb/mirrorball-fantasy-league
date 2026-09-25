-- Mirrorball Fantasy League: 48-hour trade windows and private trade history.
-- Run after add-manager-trading.sql.

begin;

alter table public.trade_offers
  add column if not exists expires_at timestamptz not null default (now() + interval '48 hours');

create index if not exists trade_offers_expiration_idx on public.trade_offers (expires_at);

drop policy if exists "managers read their trades" on public.trade_offers;
create policy "managers read their trades"
on public.trade_offers
for select
to authenticated
using (
  expires_at > now()
  and (
    initiator_team_id = public.current_league_team_id()
    or counterparty_team_id = public.current_league_team_id()
  )
);

create table if not exists public.trade_history (
  id uuid primary key default gen_random_uuid(),
  trade_id uuid not null,
  event_type text not null check (event_type in ('countered', 'accepted', 'denied', 'expired')),
  initiator_team_id uuid references public.fantasy_teams(id) on delete set null,
  counterparty_team_id uuid references public.fantasy_teams(id) on delete set null,
  initiator_team_name text not null,
  counterparty_team_name text not null,
  initiator_cast_member_id uuid references public.cast_members(id) on delete set null,
  counterparty_cast_member_id uuid references public.cast_members(id) on delete set null,
  initiator_cast_member_name text not null,
  counterparty_cast_member_name text not null,
  event_at timestamptz not null default now()
);

create index if not exists trade_history_initiator_team_idx on public.trade_history (initiator_team_id, event_at desc);
create index if not exists trade_history_counterparty_team_idx on public.trade_history (counterparty_team_id, event_at desc);

alter table public.trade_history enable row level security;
revoke all on public.trade_history from anon, authenticated;

create or replace function public.record_trade_history_event(
  p_trade public.trade_offers,
  p_event_type text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_initiator_team_name text;
  v_counterparty_team_name text;
  v_initiator_cast_name text;
  v_counterparty_cast_name text;
begin
  if p_event_type not in ('countered', 'accepted', 'denied', 'expired') then
    raise exception 'Invalid trade history event.';
  end if;

  select coalesce(team_name, split_part(manager_name, ' ', 1) || '''s Team')
    into v_initiator_team_name from public.fantasy_teams where id = p_trade.initiator_team_id;
  select coalesce(team_name, split_part(manager_name, ' ', 1) || '''s Team')
    into v_counterparty_team_name from public.fantasy_teams where id = p_trade.counterparty_team_id;
  select name into v_initiator_cast_name from public.cast_members where id = p_trade.initiator_cast_member_id;
  select name into v_counterparty_cast_name from public.cast_members where id = p_trade.counterparty_cast_member_id;

  insert into public.trade_history (
    trade_id, event_type,
    initiator_team_id, counterparty_team_id,
    initiator_team_name, counterparty_team_name,
    initiator_cast_member_id, counterparty_cast_member_id,
    initiator_cast_member_name, counterparty_cast_member_name
  ) values (
    p_trade.id, p_event_type,
    p_trade.initiator_team_id, p_trade.counterparty_team_id,
    coalesce(v_initiator_team_name, 'Former team'), coalesce(v_counterparty_team_name, 'Former team'),
    p_trade.initiator_cast_member_id, p_trade.counterparty_cast_member_id,
    coalesce(v_initiator_cast_name, 'Former cast member'), coalesce(v_counterparty_cast_name, 'Former cast member')
  );
end;
$$;

create or replace function public.expire_trade_offers_locked()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trade public.trade_offers;
  v_count integer := 0;
begin
  for v_trade in
    select * from public.trade_offers where expires_at <= now() for update
  loop
    perform public.record_trade_history_event(v_trade, 'expired');
    delete from public.trade_offers where id = v_trade.id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.get_my_trade_offers()
returns setof public.trade_offers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_team_id uuid;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  return query
    select offer.* from public.trade_offers offer
    where offer.initiator_team_id = v_my_team_id or offer.counterparty_team_id = v_my_team_id
    order by offer.updated_at desc;
end;
$$;

create or replace function public.get_my_trade_history()
returns setof public.trade_history
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_team_id uuid;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  return query
    select h.* from public.trade_history h
    where h.initiator_team_id = v_my_team_id or h.counterparty_team_id = v_my_team_id
    order by h.event_at desc;
end;
$$;

create or replace function public.request_trade(
  p_my_cast_member_id uuid,
  p_requested_cast_member_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_team_id uuid;
  v_other_team_id uuid;
  v_trade_id uuid;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  if p_my_cast_member_id = p_requested_cast_member_id then raise exception 'Choose two different cast members.'; end if;

  perform 1 from public.cast_members where id in (p_my_cast_member_id, p_requested_cast_member_id) for update;
  if (select fantasy_team_id from public.cast_members where id = p_my_cast_member_id) is distinct from v_my_team_id then
    raise exception 'The cast member you are offering is no longer on your team.';
  end if;
  select fantasy_team_id into v_other_team_id from public.cast_members where id = p_requested_cast_member_id;
  if v_other_team_id is null or v_other_team_id = v_my_team_id then
    raise exception 'Choose a cast member from another fantasy team.';
  end if;
  if exists (
    select 1 from public.trade_offers
    where p_my_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
       or p_requested_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
  ) then
    raise exception 'One of these cast members is already part of an active trade offer.';
  end if;

  insert into public.trade_offers (
    initiator_team_id, counterparty_team_id,
    initiator_cast_member_id, counterparty_cast_member_id,
    status, awaiting_team_id, expires_at
  ) values (
    v_my_team_id, v_other_team_id,
    p_my_cast_member_id, p_requested_cast_member_id,
    'pending', v_other_team_id, now() + interval '48 hours'
  ) returning id into v_trade_id;
  return v_trade_id;
end;
$$;

create or replace function public.counter_trade(
  p_trade_id uuid,
  p_initiator_cast_member_id uuid,
  p_counterparty_cast_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_team_id uuid;
  v_trade public.trade_offers;
  v_changed_count integer;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_trade.status <> 'pending' or v_trade.awaiting_team_id <> v_my_team_id or v_trade.counterparty_team_id <> v_my_team_id then
    raise exception 'This trade cannot be countered by your team.';
  end if;
  v_changed_count :=
    (case when p_initiator_cast_member_id is distinct from v_trade.initiator_cast_member_id then 1 else 0 end) +
    (case when p_counterparty_cast_member_id is distinct from v_trade.counterparty_cast_member_id then 1 else 0 end);
  if v_changed_count <> 1 then raise exception 'A counter must change exactly one side of the offer.'; end if;
  if p_initiator_cast_member_id = p_counterparty_cast_member_id then raise exception 'Choose two different cast members.'; end if;

  perform 1 from public.cast_members where id in (p_initiator_cast_member_id, p_counterparty_cast_member_id) for update;
  if (select fantasy_team_id from public.cast_members where id = p_initiator_cast_member_id) is distinct from v_trade.initiator_team_id then
    raise exception 'The requested cast member is no longer on the original manager’s team.';
  end if;
  if (select fantasy_team_id from public.cast_members where id = p_counterparty_cast_member_id) is distinct from v_trade.counterparty_team_id then
    raise exception 'The cast member you are offering is no longer on your team.';
  end if;
  if exists (
    select 1 from public.trade_offers
    where id <> p_trade_id
      and (
        p_initiator_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
        or p_counterparty_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
      )
  ) then
    raise exception 'One of these cast members is already part of another active trade offer.';
  end if;

  update public.trade_offers
  set initiator_cast_member_id = p_initiator_cast_member_id,
      counterparty_cast_member_id = p_counterparty_cast_member_id,
      status = 'countered',
      awaiting_team_id = initiator_team_id,
      updated_at = now(),
      expires_at = now() + interval '48 hours'
  where id = p_trade_id
  returning * into v_trade;
  perform public.record_trade_history_event(v_trade, 'countered');
end;
$$;

create or replace function public.accept_trade(p_trade_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_team_id uuid;
  v_trade public.trade_offers;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_trade.awaiting_team_id <> v_my_team_id then raise exception 'This trade is waiting for the other manager.'; end if;
  perform 1 from public.cast_members where id in (v_trade.initiator_cast_member_id, v_trade.counterparty_cast_member_id) for update;
  if (select fantasy_team_id from public.cast_members where id = v_trade.initiator_cast_member_id) is distinct from v_trade.initiator_team_id
     or (select fantasy_team_id from public.cast_members where id = v_trade.counterparty_cast_member_id) is distinct from v_trade.counterparty_team_id then
    raise exception 'A cast member changed teams after this offer was created. The trade can no longer be accepted.';
  end if;

  perform public.record_trade_history_event(v_trade, 'accepted');
  update public.cast_members
  set fantasy_team_id = case
    when id = v_trade.initiator_cast_member_id then v_trade.counterparty_team_id
    when id = v_trade.counterparty_cast_member_id then v_trade.initiator_team_id
  end
  where id in (v_trade.initiator_cast_member_id, v_trade.counterparty_cast_member_id);
  delete from public.trade_offers
  where v_trade.initiator_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
     or v_trade.counterparty_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id);
end;
$$;

create or replace function public.deny_trade(p_trade_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_team_id uuid;
  v_trade public.trade_offers;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_trade.awaiting_team_id <> v_my_team_id then raise exception 'Only the manager reviewing this offer can deny it.'; end if;
  perform public.record_trade_history_event(v_trade, 'denied');
  delete from public.trade_offers where id = p_trade_id;
end;
$$;

revoke all on function public.record_trade_history_event(public.trade_offers, text) from public, anon, authenticated;
revoke all on function public.expire_trade_offers_locked() from public, anon, authenticated;
revoke all on function public.get_my_trade_offers() from public, anon;
revoke all on function public.get_my_trade_history() from public, anon;
grant execute on function public.get_my_trade_offers() to authenticated;
grant execute on function public.get_my_trade_history() to authenticated;

commit;

notify pgrst, 'reload schema';
