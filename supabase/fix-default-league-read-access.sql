-- Run after activate-multi-league-workspaces.sql.
-- Signed-in SELECTs evaluate authenticated ALL policies that call this helper.
-- The helper returns only the public legacy league ID; it does not grant reads.
begin;

grant execute on function public.default_fantasy_league_id() to authenticated;

-- This older email-based ALL policy can write teams in any league. The
-- league-scoped owner policy and purpose-built RPCs replace it.
drop policy if exists "commissioner writes fantasy teams" on public.fantasy_teams;

commit;
notify pgrst, 'reload schema';
