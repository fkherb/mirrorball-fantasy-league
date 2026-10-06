-- Run once in the Supabase SQL editor before deploying the updated website.
begin;

-- Starting a draft is allowed during the pre-show blackout. The existing
-- pick/clock guards still hold the new draft until the week is complete.
drop trigger if exists guard_league_draft_start_airing_window on public.leagues;
-- Some deployments may retain the guard under a different trigger name.
-- Make the guard itself permissive without touching the separate pick/clock guards.
create or replace function public.guard_league_draft_start_airing_window()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  return new;
end;
$$;

alter table public.league_members
  add column if not exists auto_draft_enabled boolean not null default false;

-- Randomize within the first unfinished category. The existing eligibility
-- function remains authoritative for shared pool reserves and Flex limits.
create or replace function public.choose_ordered_random_draft_cast(
  p_league_id uuid, p_team_id uuid
) returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_cast_id uuid; v_pro integer; v_star integer; v_bonus integer;
begin
  select count(*) filter (where c.role = 'Pro'),
    count(*) filter (where c.role = 'Star'),
    count(*) filter (where c.role not in ('Pro', 'Star'))
    into v_pro, v_star, v_bonus
  from public.league_roster_assignments a
  join public.cast_members c on c.id = a.cast_member_id
  where a.league_id = p_league_id and a.fantasy_team_id = p_team_id;

  select c.id into v_cast_id from public.cast_members c
  where not exists (
    select 1 from public.league_roster_assignments a
    where a.league_id = p_league_id and a.cast_member_id = c.id
  ) and public.league_pick_is_eligible(p_league_id, p_team_id, c.id)
  order by case
    when c.role = 'Pro' and v_pro < public.league_category_limit(p_league_id, 'Pro') then 0
    when c.role = 'Star' and v_star < public.league_category_limit(p_league_id, 'Star') then 1
    when c.role not in ('Pro', 'Star')
      and v_bonus < public.league_bonus_draft_limit(p_league_id) then 2
    else 3 -- Extra Pro/Star in a permitted Flex slot.
  end, random()
  limit 1;
  return v_cast_id;
end;
$$;
revoke all on function public.choose_ordered_random_draft_cast(uuid,uuid)
  from public, anon, authenticated;

-- Called by triggers and the preference RPC. A row lock serializes it with
-- manual claims and timer picks; the session flag prevents recursive triggers.
create or replace function public.process_league_auto_draft(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_league public.leagues; v_team_count integer; v_pick_count integer;
  v_round integer; v_position integer; v_team_id uuid; v_user_id uuid;
  v_cast_id uuid; v_previous text;
begin
  if current_setting('mirrorball.auto_draft_running', true) = 'on' then return; end if;
  v_previous := current_setting('mirrorball.auto_draft_running', true);
  perform set_config('mirrorball.auto_draft_running', 'on', true);
  loop
    select * into v_league from public.leagues where id = p_league_id for update;
    exit when v_league.id is null or v_league.status <> 'drafting'
      or v_league.draft_paused_at is not null
      or v_league.draft_airing_paused_at is not null
      or public.league_draft_airing_lock_start() is not null;
    select count(*) into v_team_count from public.league_draft_order
      where league_id = p_league_id;
    select count(*) into v_pick_count from public.league_draft_picks
      where league_id = p_league_id;
    exit when v_team_count = 0 or v_pick_count >= v_team_count * v_league.roster_size;
    v_round := v_pick_count / v_team_count + 1;
    v_position := v_pick_count % v_team_count + 1;
    if v_round % 2 = 0 then v_position := v_team_count - v_position + 1; end if;
    select o.fantasy_team_id into v_team_id from public.league_draft_order o
      where o.league_id = p_league_id and o.draft_position = v_position;
    select m.user_id into v_user_id from public.league_members m
      where m.league_id = p_league_id and m.fantasy_team_id = v_team_id
        and m.status = 'active' and m.auto_draft_enabled;
    exit when v_user_id is null;
    v_cast_id := public.choose_ordered_random_draft_cast(p_league_id, v_team_id);
    if v_cast_id is null then
      raise exception 'No eligible automatic pick remains. Check the league roster limits.';
    end if;
    insert into public.league_roster_assignments
      (league_id, cast_member_id, fantasy_team_id)
      values (p_league_id, v_cast_id, v_team_id);
    insert into public.league_draft_picks
      (league_id, pick_number, round_number, fantasy_team_id,
       cast_member_id, picked_by, is_auto_pick)
      values (p_league_id, v_pick_count + 1, v_round, v_team_id,
        v_cast_id, v_user_id, true);
    if v_pick_count + 1 = v_team_count * v_league.roster_size then
      update public.leagues set status = 'active',
        draft_completed_at = clock_timestamp(),
        scoring_starts_after_week = coalesce((select max(number) from public.weeks where is_complete), 0),
        updated_at = clock_timestamp() where id = p_league_id;
    end if;
  end loop;
  perform set_config('mirrorball.auto_draft_running', coalesce(v_previous, ''), true);
end;
$$;
revoke all on function public.process_league_auto_draft(uuid)
  from public, anon, authenticated;

create or replace function public.set_league_auto_draft(
  p_league_id uuid, p_enabled boolean
) returns void language plpgsql security definer set search_path = '' as $$
declare v_league public.leagues; v_user_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to change auto-draft.'; end if;
  if p_enabled is null then raise exception 'Choose whether to enable auto-draft.'; end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id()
     or v_league.status not in ('setup', 'drafting') then
    raise exception 'Auto-draft can only change before or during a league draft.';
  end if;
  update public.league_members m set auto_draft_enabled = p_enabled,
    draft_ready_at = case
      when p_enabled and v_league.status = 'setup' and m.role = 'member'
        then coalesce(m.draft_ready_at, clock_timestamp())
      else m.draft_ready_at end,
    updated_at = clock_timestamp()
  where m.league_id = p_league_id and m.user_id = auth.uid()
    and m.status = 'active'
  returning m.user_id into v_user_id;
  if v_user_id is null then raise exception 'Only an active manager can change auto-draft.'; end if;
  if p_enabled and v_league.status = 'drafting' then
    perform public.process_league_auto_draft(p_league_id);
  end if;
end;
$$;
revoke all on function public.set_league_auto_draft(uuid,boolean) from public, anon;
grant execute on function public.set_league_auto_draft(uuid,boolean) to authenticated;

create or replace function public.process_league_auto_draft_after_pick()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('mirrorball.auto_draft_running', true) is distinct from 'on' then
    perform public.process_league_auto_draft(new.league_id);
  end if;
  return null;
end;
$$;
drop trigger if exists zz_process_league_auto_draft_after_pick on public.league_draft_picks;
create trigger zz_process_league_auto_draft_after_pick
after insert on public.league_draft_picks for each row
execute function public.process_league_auto_draft_after_pick();

create or replace function public.process_league_auto_draft_after_league_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'drafting'
    and current_setting('mirrorball.auto_draft_running', true) is distinct from 'on'
    and (old.status is distinct from new.status
      or old.draft_paused_at is distinct from new.draft_paused_at
      or old.draft_airing_paused_at is distinct from new.draft_airing_paused_at) then
    perform public.process_league_auto_draft(new.id);
  end if;
  return null;
end;
$$;
drop trigger if exists zz_process_league_auto_draft_after_league_change on public.leagues;
create trigger zz_process_league_auto_draft_after_league_change
after update of status, draft_paused_at, draft_airing_paused_at on public.leagues
for each row execute function public.process_league_auto_draft_after_league_change();

-- Keep the old timeout semantics, but use exactly the same category-aware picker.
create or replace function public.advance_league_draft_clock_without_airing_lock(p_league_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_league public.leagues; v_team_count integer; v_pick_count integer;
  v_round integer; v_position integer; v_team_id uuid; v_user_id uuid; v_cast_id uuid;
begin
  if auth.uid() is not null and not public.is_league_member(p_league_id) then
    raise exception 'League membership required.';
  end if;
  perform public.process_league_auto_draft(p_league_id);
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id() then
    raise exception 'League not found.';
  end if;
  if v_league.status = 'drafting' and not v_league.draft_timer_disabled
     and v_league.draft_paused_at is null
     and v_league.draft_airing_paused_at is null
     and v_league.draft_pick_deadline_at <= clock_timestamp() then
    select count(*) into v_team_count from public.league_draft_order
      where league_id = p_league_id;
    select count(*) into v_pick_count from public.league_draft_picks
      where league_id = p_league_id;
    if v_team_count < 1 then raise exception 'Draft order is missing.'; end if;
    if v_pick_count < v_team_count * v_league.roster_size then
      v_round := v_pick_count / v_team_count + 1;
      v_position := v_pick_count % v_team_count + 1;
      if v_round % 2 = 0 then v_position := v_team_count - v_position + 1; end if;
      select o.fantasy_team_id into v_team_id from public.league_draft_order o
        where o.league_id = p_league_id and o.draft_position = v_position;
      select m.user_id into v_user_id from public.league_members m
        where m.league_id = p_league_id and m.fantasy_team_id = v_team_id
          and m.status = 'active';
      v_cast_id := public.choose_ordered_random_draft_cast(p_league_id, v_team_id);
      if v_team_id is null or v_user_id is null or v_cast_id is null then
        raise exception 'No eligible automatic pick remains. Check the league roster limits.';
      end if;
      insert into public.league_roster_assignments
        (league_id, cast_member_id, fantasy_team_id)
        values (p_league_id, v_cast_id, v_team_id);
      insert into public.league_draft_picks
        (league_id, pick_number, round_number, fantasy_team_id,
         cast_member_id, picked_by, is_auto_pick)
        values (p_league_id, v_pick_count + 1, v_round, v_team_id,
          v_cast_id, v_user_id, true);
      if v_pick_count + 1 = v_team_count * v_league.roster_size then
        update public.leagues set status = 'active',
          draft_completed_at = clock_timestamp(),
          scoring_starts_after_week = coalesce((select max(number) from public.weeks where is_complete), 0),
          updated_at = clock_timestamp() where id = p_league_id;
      end if;
    end if;
  end if;
  select * into v_league from public.leagues where id = p_league_id;
  select count(*) into v_pick_count from public.league_draft_picks
    where league_id = p_league_id;
  return jsonb_build_object('status', v_league.status,
    'pick_count', v_pick_count, 'deadline_at', v_league.draft_pick_deadline_at,
    'server_now', clock_timestamp());
end;
$$;

commit;
notify pgrst, 'reload schema';
