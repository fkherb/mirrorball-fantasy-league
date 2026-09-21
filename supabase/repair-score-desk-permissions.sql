-- Run once in Supabase Dashboard → SQL Editor if Score Desk says “permission denied”.
grant usage on schema public to anon, authenticated;
grant select on public.dances, public.dance_judge_scores, public.dance_appearances to anon, authenticated;
grant insert, update, delete on public.dances, public.dance_judge_scores, public.dance_appearances to authenticated;

drop policy if exists "public read dances" on public.dances;
create policy "public read dances" on public.dances for select using (true);
drop policy if exists "public read judge scores" on public.dance_judge_scores;
create policy "public read judge scores" on public.dance_judge_scores for select using (true);
drop policy if exists "public read dance appearances" on public.dance_appearances;
create policy "public read dance appearances" on public.dance_appearances for select using (true);

drop policy if exists "commissioner writes dances" on public.dances;
create policy "commissioner writes dances" on public.dances for all to authenticated using ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com') with check ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com');
drop policy if exists "commissioner writes judge scores" on public.dance_judge_scores;
create policy "commissioner writes judge scores" on public.dance_judge_scores for all to authenticated using ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com') with check ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com');
drop policy if exists "commissioner writes dance appearances" on public.dance_appearances;
create policy "commissioner writes dance appearances" on public.dance_appearances for all to authenticated using ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com') with check ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com');
