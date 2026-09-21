-- Replace YOUR_COMMISSIONER_EMAIL before running in Supabase SQL Editor.
create policy "commissioner writes teams" on public.fantasy_teams for all to authenticated using ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL') with check ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL');
create policy "commissioner writes weeks" on public.weeks for all to authenticated using ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL') with check ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL');
create policy "commissioner writes players" on public.players for all to authenticated using ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL') with check ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL');
create policy "commissioner writes partnerships" on public.partnerships for all to authenticated using ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL') with check ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL');
create policy "commissioner writes rosters" on public.roster_history for all to authenticated using ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL') with check ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL');
create policy "commissioner writes scores" on public.score_events for all to authenticated using ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL') with check ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL');
