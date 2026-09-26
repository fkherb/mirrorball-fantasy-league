-- Mirrorball Fantasy League: keep accepted and denied trade results visible
-- to the manager who sent the latest offer until that manager dismisses them.
-- Run after prepare-multi-league-foundation.sql.

begin;

alter table public.trade_history
  add column if not exists notification_team_id uuid references public.fantasy_teams(id) on delete set null,
  add column if not exists dismissed_at timestamptz;

alter table public.trade_history
  drop constraint if exists trade_history_notification_event_check;
alter table public.trade_history
  add constraint trade_history_notification_event_check
  check (notification_team_id is null or event_type in ('accepted', 'denied'));

create index if not exists trade_history_unread_result_idx
  on public.trade_history (notification_team_id, event_at desc)
  where notification_team_id is not null and dismissed_at is null;

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
  v_notification_team_id uuid;
begin
  if p_event_type not in ('countered', 'accepted', 'denied', 'expired', 'cancelled', 'invalidated') then
    raise exception 'Invalid trade history event.';
  end if;

  select coalesce(team_name, split_part(manager_name, ' ', 1) || '''s Team')
    into v_initiator_team_name from public.fantasy_teams where id = p_trade.initiator_team_id;
  select coalesce(team_name, split_part(manager_name, ' ', 1) || '''s Team')
    into v_counterparty_team_name from public.fantasy_teams where id = p_trade.counterparty_team_id;
  select name into v_initiator_cast_name from public.cast_members where id = p_trade.initiator_cast_member_id;
  select name into v_counterparty_cast_name from public.cast_members where id = p_trade.counterparty_cast_member_id;

  -- For an accepted or denied offer, notify whichever team sent the exact
  -- offer being answered. This also works after a counter reverses who is
  -- awaiting the response.
  if p_event_type in ('accepted', 'denied') then
    v_notification_team_id := case
      when p_trade.awaiting_team_id = p_trade.initiator_team_id then p_trade.counterparty_team_id
      else p_trade.initiator_team_id
    end;
  end if;

  insert into public.trade_history (
    trade_id, event_type,
    initiator_team_id, counterparty_team_id,
    initiator_team_name, counterparty_team_name,
    initiator_cast_member_id, counterparty_cast_member_id,
    initiator_cast_member_name, counterparty_cast_member_name,
    notification_team_id
  ) values (
    p_trade.id, p_event_type,
    p_trade.initiator_team_id, p_trade.counterparty_team_id,
    coalesce(v_initiator_team_name, 'Former team'), coalesce(v_counterparty_team_name, 'Former team'),
    p_trade.initiator_cast_member_id, p_trade.counterparty_cast_member_id,
    coalesce(v_initiator_cast_name, 'Former cast member'), coalesce(v_counterparty_cast_name, 'Former cast member'),
    v_notification_team_id
  );
end;
$$;

create or replace function public.get_my_trade_result_notifications()
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
  return query
    select history.*
    from public.trade_history as history
    where history.notification_team_id = v_my_team_id
      and history.dismissed_at is null
      and history.event_type in ('accepted', 'denied')
    order by history.event_at desc;
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
    select history.*
    from public.trade_history as history
    where (history.initiator_team_id = v_my_team_id or history.counterparty_team_id = v_my_team_id)
      and (
        history.notification_team_id is distinct from v_my_team_id
        or history.dismissed_at is not null
      )
    order by history.event_at desc;
end;
$$;

create or replace function public.dismiss_trade_result(p_history_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_team_id uuid;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;

  update public.trade_history
  set dismissed_at = now()
  where id = p_history_id
    and notification_team_id = v_my_team_id
    and dismissed_at is null;

  if not found then raise exception 'This trade result is no longer available.'; end if;
end;
$$;

revoke all on function public.record_trade_history_event(public.trade_offers, text) from public, anon, authenticated;
revoke all on function public.get_my_trade_result_notifications() from public, anon;
revoke all on function public.get_my_trade_history() from public, anon;
revoke all on function public.dismiss_trade_result(uuid) from public, anon;
grant execute on function public.get_my_trade_result_notifications() to authenticated;
grant execute on function public.get_my_trade_history() to authenticated;
grant execute on function public.dismiss_trade_result(uuid) to authenticated;

commit;

notify pgrst, 'reload schema';
