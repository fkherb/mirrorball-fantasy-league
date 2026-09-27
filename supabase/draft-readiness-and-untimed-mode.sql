-- Run after pause-league-draft.sql. Adds member readiness and an optional
-- untimed, manual-pick draft. Safe to rerun; existing drafts stay timed.
begin;

alter table public.league_members
  add column if not exists draft_ready_at timestamptz;
alter table public.leagues
  add column if not exists draft_timer_disabled boolean not null default false;

create or replace function public.get_league_draft_readiness(p_league_id uuid)
returns table (user_id uuid, ready_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_league_member(p_league_id) then
    raise exception 'League membership required.';
  end if;
  return query select member.user_id, member.draft_ready_at
  from public.league_members member
  where member.league_id = p_league_id and member.status = 'active';
end;
$$;
revoke all on function public.get_league_draft_readiness(uuid) from public, anon;
grant execute on function public.get_league_draft_readiness(uuid) to authenticated;

create or replace function public.set_league_draft_ready(p_league_id uuid, p_ready boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare v_league public.leagues; v_user_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to get ready for the draft.'; end if;
  if p_ready is null then raise exception 'Choose ready or unready.'; end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id()
     or v_league.status <> 'setup' then
    raise exception 'Readiness can only change before a league draft starts.';
  end if;
  update public.league_members member
  set draft_ready_at = case when p_ready then clock_timestamp() else null end,
      updated_at = clock_timestamp()
  where member.league_id = p_league_id and member.user_id = auth.uid()
    and member.status = 'active' and member.role = 'member'
  returning member.user_id into v_user_id;
  if v_user_id is null then
    raise exception 'Only regular league members can change readiness.';
  end if;
end;
$$;
revoke all on function public.set_league_draft_ready(uuid,boolean) from public, anon;
grant execute on function public.set_league_draft_ready(uuid,boolean) to authenticated;

-- Keep the one-argument RPC as a checked compatibility path for cached pages.
create or replace function public.start_league_draft(p_league_id uuid, p_disable_timer boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare v_league public.leagues; v_team_count integer;
begin
  if p_disable_timer is null then raise exception 'Choose a draft clock setting.'; end if;
  if not public.is_league_owner(p_league_id) then
    raise exception 'League owner access required.';
  end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id()
     or v_league.status <> 'setup' then
    raise exception 'The draft has already started or the league was not found.';
  end if;
  select count(*) into v_team_count from public.league_members
  where league_id = p_league_id and status = 'active';
  if v_team_count not between 3 and 6 then
    raise exception 'Invite 3 to 6 managers before starting the draft.';
  end if;
  if exists (select 1 from public.league_members member
    where member.league_id = p_league_id and member.status = 'active'
      and member.role = 'member' and member.draft_ready_at is null) then
    raise exception 'All regular managers must be ready before the draft starts.';
  end if;
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
  update public.leagues set status = 'drafting', draft_started_at = now(),
    draft_timer_disabled = p_disable_timer, draft_paused_at = null,
    draft_seconds_remaining = null, updated_at = now()
  where id = p_league_id;
end;
$$;
create or replace function public.start_league_draft(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.start_league_draft(p_league_id, false);
end;
$$;
revoke all on function public.start_league_draft(uuid,boolean),
  public.start_league_draft(uuid) from public, anon;
grant execute on function public.start_league_draft(uuid,boolean),
  public.start_league_draft(uuid) to authenticated;

create or replace function public.set_league_draft_deadline()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'drafting' and old.status is distinct from 'drafting' then
    new.draft_pick_deadline_at := case when new.draft_timer_disabled then null
      else clock_timestamp() + interval '2 minutes' end;
  elsif new.status <> 'drafting' then
    new.draft_pick_deadline_at := null;
  end if;
  return new;
end;
$$;

create or replace function public.advance_league_draft_deadline_after_pick()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_total integer;
begin
  select league.roster_size * count(*)::integer into v_total
  from public.leagues league
  join public.league_draft_order draft_order on draft_order.league_id = league.id
  where league.id = new.league_id
  group by league.roster_size;
  update public.leagues set draft_pick_deadline_at =
    case when draft_timer_disabled or new.pick_number >= v_total then null
      else clock_timestamp() + interval '2 minutes' end,
    updated_at = clock_timestamp()
  where id = new.league_id and status = 'drafting';
  return null;
end;
$$;

create or replace function public.set_league_draft_paused(p_league_id uuid, p_paused boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare v_league public.leagues; v_remaining integer;
begin
  if p_paused is null then raise exception 'Choose whether to pause or resume the draft.'; end if;
  if not public.is_league_owner(p_league_id) then
    raise exception 'Only the league owner can pause or resume the draft.';
  end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id()
     or v_league.status <> 'drafting' then
    raise exception 'Only an active draft can be paused or resumed.';
  end if;
  if v_league.draft_timer_disabled then
    raise exception 'Untimed drafts do not have a clock to pause.';
  end if;
  if p_paused and v_league.draft_paused_at is null then
    v_remaining := least(120, greatest(0, coalesce(ceil(extract(epoch from
      v_league.draft_pick_deadline_at - clock_timestamp()))::integer, 120)));
    update public.leagues set
      draft_seconds_remaining = v_remaining,
      draft_pick_deadline_at = null,
      draft_paused_at = clock_timestamp(),
      updated_at = clock_timestamp()
    where id = p_league_id;
  elsif not p_paused and v_league.draft_paused_at is not null then
    update public.leagues set
      draft_pick_deadline_at = clock_timestamp()
        + make_interval(secs => coalesce(v_league.draft_seconds_remaining, 120)),
      draft_paused_at = null,
      draft_seconds_remaining = null,
      updated_at = clock_timestamp()
    where id = p_league_id;
  end if;
end;
$$;

-- A disabled timer must never block a manual pick, even if a stale deadline
-- remains from an older site or migration.
create or replace function public.enforce_league_draft_pick_clock()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_deadline timestamptz; v_paused_at timestamptz; v_timer_disabled boolean;
begin
  select draft_pick_deadline_at, draft_paused_at, draft_timer_disabled
    into v_deadline, v_paused_at, v_timer_disabled
  from public.leagues where id = new.league_id;
  if v_paused_at is not null then raise exception 'This draft is paused.'; end if;
  if not coalesce(v_timer_disabled, false) and not new.is_auto_pick
     and v_deadline is not null and clock_timestamp() >= v_deadline then
    raise exception 'This turn has expired. Wait for the automatic pick.';
  end if;
  return new;
end;
$$;

create or replace function public.advance_league_draft_clock(p_league_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_league public.leagues;
  v_team_count integer;
  v_pick_count integer;
  v_round integer;
  v_position integer;
  v_team_id uuid;
  v_user_id uuid;
  v_cast_id uuid;
begin
  if auth.uid() is not null and not public.is_league_member(p_league_id) then
    raise exception 'League membership required.';
  end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id() then
    raise exception 'League not found.';
  end if;
  if v_league.status = 'drafting' and not v_league.draft_timer_disabled
     and v_league.draft_pick_deadline_at <= clock_timestamp() then
    select count(*) into v_team_count from public.league_draft_order
      where league_id = p_league_id;
    select count(*) into v_pick_count from public.league_draft_picks
      where league_id = p_league_id;
    if v_team_count < 1 then raise exception 'Draft order is missing.'; end if;
    if v_pick_count < v_team_count * v_league.roster_size then
      v_round := v_pick_count / v_team_count + 1;
      v_position := v_pick_count % v_team_count + 1;
      if v_round % 2 = 0 then
        v_position := v_team_count - v_position + 1;
      end if;
      select draft_order.fantasy_team_id into v_team_id
      from public.league_draft_order draft_order
      where draft_order.league_id = p_league_id
        and draft_order.draft_position = v_position;
      select member.user_id into v_user_id from public.league_members member
      where member.league_id = p_league_id and member.fantasy_team_id = v_team_id
        and member.status = 'active';
      select cast_member.id into v_cast_id from public.cast_members cast_member
      where not exists (select 1 from public.league_roster_assignments assignment
        where assignment.league_id = p_league_id
          and assignment.cast_member_id = cast_member.id)
      order by random() limit 1;
      if v_team_id is null or v_user_id is null or v_cast_id is null then
        raise exception 'The draft cannot make an automatic pick. Check its teams and cast pool.';
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
        update public.leagues set status = 'active', draft_completed_at = clock_timestamp(),
          scoring_starts_after_week = 0, updated_at = clock_timestamp()
        where id = p_league_id;
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

create or replace function public.process_expired_league_drafts()
returns void language plpgsql security definer set search_path = '' as $$
declare v_league_id uuid;
begin
  for v_league_id in select id from public.leagues
    where status = 'drafting' and not draft_timer_disabled
      and draft_pick_deadline_at <= clock_timestamp()
  loop
    perform public.advance_league_draft_clock(v_league_id);
  end loop;
end;
$$;

revoke all on function public.set_league_draft_deadline(),
  public.advance_league_draft_deadline_after_pick(),
  public.enforce_league_draft_pick_clock(),
  public.process_expired_league_drafts() from public, anon, authenticated;
revoke all on function public.set_league_draft_paused(uuid,boolean) from public, anon;
grant execute on function public.set_league_draft_paused(uuid,boolean) to authenticated;
revoke all on function public.advance_league_draft_clock(uuid) from public, anon;
grant execute on function public.advance_league_draft_clock(uuid) to authenticated;

commit;
notify pgrst, 'reload schema';
