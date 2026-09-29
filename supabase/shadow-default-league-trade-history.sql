-- Prepare historical default-league trades for the shared workspace.
-- This does not migrate open offers, change trade RPCs, or switch the website.
-- Run after activate-multi-league-workspaces.sql and
-- add-trade-result-notifications.sql. Safe to rerun.
begin;

do $$
begin
  if exists (select 1 from public.trade_history
    where league_id = public.default_fantasy_league_id()
      and (initiator_team_id is null or counterparty_team_id is null)) then
    raise exception 'Historical trades with deleted teams need a manual mapping before mirroring.';
  end if;
end;
$$;

create or replace function public.mirror_default_league_trade_history()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.league_id = public.default_fantasy_league_id() then
    -- A later deleted team may clear the nullable legacy FK. Keep the already
    -- copied event's historical team IDs instead of blocking that deletion.
    if new.initiator_team_id is null or new.counterparty_team_id is null then
      return new;
    end if;
    insert into public.league_trade_events
      (id, league_id, trade_id, event_type, initiator_team_id,
       counterparty_team_id, initiator_cast_member_name,
       counterparty_cast_member_name, notification_team_id,
       dismissed_at, event_at)
    values
      (new.id, new.league_id, new.trade_id, new.event_type,
       new.initiator_team_id, new.counterparty_team_id,
       new.initiator_cast_member_name, new.counterparty_cast_member_name,
       new.notification_team_id, new.dismissed_at, new.event_at)
    on conflict (id) do update set
      league_id = excluded.league_id,
      trade_id = excluded.trade_id,
      event_type = excluded.event_type,
      initiator_team_id = excluded.initiator_team_id,
      counterparty_team_id = excluded.counterparty_team_id,
      initiator_cast_member_name = excluded.initiator_cast_member_name,
      counterparty_cast_member_name = excluded.counterparty_cast_member_name,
      notification_team_id = excluded.notification_team_id,
      dismissed_at = excluded.dismissed_at,
      event_at = excluded.event_at;
  end if;
  return new;
end;
$$;
revoke all on function public.mirror_default_league_trade_history() from public, anon, authenticated;
drop trigger if exists mirror_default_league_trade_history on public.trade_history;
create trigger mirror_default_league_trade_history
after insert or update on public.trade_history
for each row execute function public.mirror_default_league_trade_history();

insert into public.league_trade_events
  (id, league_id, trade_id, event_type, initiator_team_id,
   counterparty_team_id, initiator_cast_member_name,
   counterparty_cast_member_name, notification_team_id,
   dismissed_at, event_at)
select history.id, history.league_id, history.trade_id, history.event_type,
  history.initiator_team_id, history.counterparty_team_id,
  history.initiator_cast_member_name, history.counterparty_cast_member_name,
  history.notification_team_id, history.dismissed_at, history.event_at
from public.trade_history history
where history.league_id = public.default_fantasy_league_id()
on conflict (id) do update set
  league_id = excluded.league_id,
  trade_id = excluded.trade_id,
  event_type = excluded.event_type,
  initiator_team_id = excluded.initiator_team_id,
  counterparty_team_id = excluded.counterparty_team_id,
  initiator_cast_member_name = excluded.initiator_cast_member_name,
  counterparty_cast_member_name = excluded.counterparty_cast_member_name,
  notification_team_id = excluded.notification_team_id,
  dismissed_at = excluded.dismissed_at,
  event_at = excluded.event_at;

commit;
