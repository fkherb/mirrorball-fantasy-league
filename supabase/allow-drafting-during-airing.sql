-- Draft turns, including automatic picks, continue through an airing.
-- This does not change the separate trade/free-agent roster airing lock.
begin;
create or replace function public.league_draft_airing_lock_start(
  p_at timestamptz default clock_timestamp()
) returns timestamptz language sql stable security definer set search_path = '' as $$
  select null::timestamptz;
$$;

-- Resume drafts that entered the airing pause before this change. The normal
-- clock function restores any saved time and processes opted-in auto-picks.
do $$
declare v_league_id uuid;
begin
  for v_league_id in select id from public.leagues where status = 'drafting' loop
    perform public.advance_league_draft_clock(v_league_id);
  end loop;
end;
$$;
commit;
