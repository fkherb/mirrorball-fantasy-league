-- Mirrorball Fantasy League: manager-account foundation
-- Run once before linking additional Supabase Auth users to fantasy teams.

create table if not exists public.league_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  first_name text not null check (length(trim(first_name)) > 0),
  last_name text not null check (length(trim(last_name)) > 0),
  fantasy_team_id uuid unique references public.fantasy_teams(id) on delete set null,
  is_commissioner boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.league_members enable row level security;

-- This security-definer helper avoids recursive RLS checks when policies need
-- to determine whether the current account is the league commissioner.
create or replace function public.is_league_commissioner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.league_members
    where user_id = auth.uid()
      and is_commissioner = true
  );
$$;

revoke all on function public.is_league_commissioner() from public;
grant execute on function public.is_league_commissioner() to authenticated;

drop policy if exists "members read own account" on public.league_members;
create policy "members read own account"
on public.league_members
for select
to authenticated
using (user_id = auth.uid());

drop policy if exists "commissioner reads league members" on public.league_members;
create policy "commissioner reads league members"
on public.league_members
for select
to authenticated
using (public.is_league_commissioner());

drop policy if exists "commissioner manages league members" on public.league_members;
create policy "commissioner manages league members"
on public.league_members
for all
to authenticated
using (public.is_league_commissioner())
with check (public.is_league_commissioner());

grant select, insert, update, delete on public.league_members to authenticated;

-- Managers may update only their own first and last names through this RPC.
-- They cannot use it to change their team or grant commissioner access.
create or replace function public.update_my_league_name(
  p_first_name text,
  p_last_name text
)
returns public.league_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated_member public.league_members;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;
  if length(trim(coalesce(p_first_name, ''))) = 0
     or length(trim(coalesce(p_last_name, ''))) = 0 then
    raise exception 'First and last name are required.';
  end if;

  update public.league_members
  set first_name = trim(p_first_name),
      last_name = trim(p_last_name),
      updated_at = now()
  where user_id = auth.uid()
  returning * into updated_member;

  if updated_member.user_id is null then
    raise exception 'This account has not been added to the league.';
  end if;

  return updated_member;
end;
$$;

revoke all on function public.update_my_league_name(text, text) from public;
grant execute on function public.update_my_league_name(text, text) to authenticated;

