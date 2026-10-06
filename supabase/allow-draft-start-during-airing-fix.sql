-- Run this small follow-up if ordered-auto-draft.sql was already applied.
-- It removes only the start veto; picks and the clock still pause for airing.
begin;
drop trigger if exists guard_league_draft_start_airing_window on public.leagues;
create or replace function public.guard_league_draft_start_airing_window()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  return new;
end;
$$;
commit;
