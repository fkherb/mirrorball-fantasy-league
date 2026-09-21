-- Run once in Supabase Dashboard → SQL Editor after the cast_members migration.
alter table public.weeks add column if not exists theme text;
alter table public.weeks add column if not exists title text;
alter table public.weeks add column if not exists guest_judge_name text;
alter table public.weeks add column if not exists double_elimination boolean not null default false;

create table if not exists public.dances (
  id uuid primary key default gen_random_uuid(),
  week_id uuid not null references public.weeks(id) on delete cascade,
  kind text not null check (kind in ('competitive','performance')),
  partnership_id uuid references public.partnerships(id),
  name text,
  sort_order integer not null default 0
);

create table if not exists public.dance_judge_scores (
  id uuid primary key default gen_random_uuid(),
  dance_id uuid not null references public.dances(id) on delete cascade,
  judge_name text not null,
  score integer not null check (score between 0 and 10),
  unique (dance_id, judge_name)
);

create table if not exists public.dance_appearances (
  id uuid primary key default gen_random_uuid(),
  dance_id uuid not null references public.dances(id) on delete cascade,
  cast_member_id uuid not null references public.cast_members(id),
  unique (dance_id, cast_member_id)
);

alter table public.dances enable row level security;
alter table public.dance_judge_scores enable row level security;
alter table public.dance_appearances enable row level security;

create policy "public read dances" on public.dances for select using (true);
create policy "public read judge scores" on public.dance_judge_scores for select using (true);
create policy "public read dance appearances" on public.dance_appearances for select using (true);

create policy "commissioner writes dances" on public.dances for all to authenticated using ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com') with check ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com');
create policy "commissioner writes judge scores" on public.dance_judge_scores for all to authenticated using ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com') with check ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com');
create policy "commissioner writes dance appearances" on public.dance_appearances for all to authenticated using ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com') with check ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com');
