-- Run after league-limits-and-full-deletion.sql. Existing drafts get a fresh
-- two-minute turn on deployment; no cast member is selected during migration.
begin;

alter table public.leagues
  add column if not exists draft_pick_deadline_at timestamptz;
alter table public.league_draft_picks
  add column if not exists is_auto_pick boolean not null default false;

create or replace function public.set_league_draft_deadline()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'drafting' and old.status is distinct from 'drafting' then
    new.draft_pick_deadline_at := clock_timestamp() + interval '2 minutes';
  elsif new.status <> 'drafting' then
    new.draft_pick_deadline_at := null;
  end if;
  return new;
end;
$$;
drop trigger if exists set_league_draft_deadline on public.leagues;
create trigger set_league_draft_deadline
before update of status on public.leagues
for each row execute function public.set_league_draft_deadline();

create or replace function public.enforce_league_draft_pick_clock()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_deadline timestamptz;
begin
  select draft_pick_deadline_at into v_deadline from public.leagues
  where id = new.league_id;
  if not new.is_auto_pick and v_deadline is not null
    and clock_timestamp() >= v_deadline then
    raise exception 'This turn has expired. Wait for the automatic pick.';
  end if;
  return new;
end;
$$;
drop trigger if exists enforce_league_draft_pick_clock on public.league_draft_picks;
create trigger enforce_league_draft_pick_clock
before insert on public.league_draft_picks
for each row execute function public.enforce_league_draft_pick_clock();

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
    case when new.pick_number >= v_total then null
      else clock_timestamp() + interval '2 minutes' end,
    updated_at = clock_timestamp()
  where id = new.league_id and status = 'drafting';
  return null;
end;
$$;
drop trigger if exists advance_league_draft_deadline_after_pick on public.league_draft_picks;
create trigger advance_league_draft_deadline_after_pick
after insert on public.league_draft_picks
for each row execute function public.advance_league_draft_deadline_after_pick();

-- Give drafts already in progress a full turn when this migration is applied.
update public.leagues set draft_pick_deadline_at = clock_timestamp() + interval '2 minutes'
where status = 'drafting';

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
  if v_league.status = 'drafting' and v_league.draft_pick_deadline_at <= clock_timestamp() then
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
revoke all on function public.advance_league_draft_clock(uuid) from public, anon;
grant execute on function public.advance_league_draft_clock(uuid) to authenticated;
revoke all on function public.set_league_draft_deadline(),
  public.enforce_league_draft_pick_clock(),
  public.advance_league_draft_deadline_after_pick()
  from public, anon, authenticated;

create or replace function public.process_expired_league_drafts()
returns void language plpgsql security definer set search_path = '' as $$
declare v_league_id uuid;
begin
  for v_league_id in select id from public.leagues
    where status = 'drafting' and draft_pick_deadline_at <= clock_timestamp()
  loop
    perform public.advance_league_draft_clock(v_league_id);
  end loop;
end;
$$;
revoke all on function public.process_expired_league_drafts() from public, anon, authenticated;

-- If pg_cron is installed, keep drafts moving even when every browser closes.
-- Browser polling below also advances overdue turns when pg_cron is absent.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'mirrorball-draft-clock') then
      perform cron.unschedule('mirrorball-draft-clock');
    end if;
    perform cron.schedule('mirrorball-draft-clock', '* * * * *',
      'select public.process_expired_league_drafts()');
  end if;
end;
$$;

commit;
notify pgrst, 'reload schema';
