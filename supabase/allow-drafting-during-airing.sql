-- Draft turns, including automatic picks, continue through an airing.
-- This does not change the separate trade/free-agent roster airing lock.
begin;
create or replace function public.league_draft_airing_lock_start(
  p_at timestamptz default clock_timestamp()
) returns timestamptz language sql stable security definer set search_path = '' as $$
  select null::timestamptz;
$$;
commit;

-- The next draft-clock poll (or scheduled check) resumes any draft that was
-- already paused for airing, preserving its saved remaining pick time.
