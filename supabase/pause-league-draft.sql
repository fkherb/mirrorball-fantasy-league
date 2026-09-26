-- Run after live-draft-clock.sql. Pauses only secondary-league drafts;
-- current picks and draft order are preserved. Run once before deploying the UI.
begin;

alter table public.leagues
  add column if not exists draft_paused_at timestamptz,
  add column if not exists draft_seconds_remaining integer;

alter table public.leagues drop constraint if exists leagues_draft_seconds_remaining_check;
alter table public.leagues add constraint leagues_draft_seconds_remaining_check
  check (draft_seconds_remaining between 0 and 120);

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
revoke all on function public.set_league_draft_paused(uuid,boolean) from public, anon;
grant execute on function public.set_league_draft_paused(uuid,boolean) to authenticated;

-- An old browser may still show a Claim button. Reject it on the server while
-- paused, including if the owner pauses between opening and confirming a pick.
create or replace function public.enforce_league_draft_pick_clock()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_deadline timestamptz; v_paused_at timestamptz;
begin
  select draft_pick_deadline_at, draft_paused_at into v_deadline, v_paused_at
  from public.leagues where id = new.league_id;
  if v_paused_at is not null then raise exception 'This draft is paused.'; end if;
  if not new.is_auto_pick and v_deadline is not null
     and clock_timestamp() >= v_deadline then
    raise exception 'This turn has expired. Wait for the automatic pick.';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_league_draft_pick_clock() from public, anon, authenticated;

commit;
notify pgrst, 'reload schema';
