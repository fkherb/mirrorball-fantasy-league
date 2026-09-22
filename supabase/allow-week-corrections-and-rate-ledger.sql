-- RUN THIS ONCE after harden-score-desk-and-role-rates.sql.
-- It keeps completed weeks as historical roster/rate checkpoints while letting
-- the commissioner correct their dances, scores, appearances, and setup.

begin;

-- Remove the old completed-week lock before touching existing completed rows.
-- The duplicate-dance and competing-pair safeguards remain in force.
drop trigger if exists prevent_completed_dance_edit on public.dances;
drop trigger if exists prevent_completed_judge_score_edit on public.dance_judge_scores;
drop trigger if exists prevent_completed_appearance_edit on public.dance_appearances;
drop trigger if exists prevent_completed_week_metadata_edit on public.weeks;

-- Save a surprise cast member's custom rate with the week roster. Default role
-- rates live in the new table below.
alter table public.weekly_roster_snapshots
  add column if not exists appearance_points integer;
alter table public.weeks
  add column if not exists uses_rate_snapshots boolean not null default false;

create table if not exists public.weekly_role_rates (
  week_id uuid not null references public.weeks(id) on delete cascade,
  role text not null references public.roles(name) on update cascade,
  appearance_points integer not null check (appearance_points between 0 and 99),
  primary key (week_id, role)
);
alter table public.weekly_role_rates enable row level security;
grant select on public.weekly_role_rates to anon, authenticated;
grant insert, update, delete on public.weekly_role_rates to authenticated;
drop policy if exists "public read weekly role rates" on public.weekly_role_rates;
create policy "public read weekly role rates" on public.weekly_role_rates for select using (true);
drop policy if exists "commissioner writes weekly role rates" on public.weekly_role_rates;
create policy "commissioner writes weekly role rates"
  on public.weekly_role_rates for all to authenticated
  using ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com');

-- Backfill completed weeks with today's configured default rates. Week 1 is
-- safe because its current rates are the rates that were used to score it.
insert into public.weekly_role_rates (week_id, role, appearance_points)
select w.id, r.name, r.appearance_points
from public.weeks as w
cross join public.roles as r
where w.is_complete and r.name <> 'Surprise'
on conflict (week_id, role) do nothing;

update public.weekly_roster_snapshots as s
set appearance_points = c.custom_appearance_points
from public.cast_members as c
where c.id = s.cast_member_id and s.cast_role = 'Surprise';

-- This flag lets the website recognize that the rate-ledger migration is ready.
update public.weeks set uses_rate_snapshots = true;

-- Completion remains atomic, but it no longer locks the Score Desk. It copies
-- each default rate and Surprise custom rate into the historical checkpoint.
create or replace function public.complete_week(
  p_week_id uuid,
  p_eliminated_partnership_ids uuid[] default '{}'
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_week public.weeks%rowtype;
  v_expected_eliminations integer;
  v_expected_judges integer;
begin
  select * into v_week from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if v_week.is_complete then raise exception 'This week is already complete.'; end if;

  v_expected_eliminations := case when v_week.is_finale then 0 when v_week.double_elimination then 2 else 1 end;
  v_expected_judges := 3 + case when nullif(trim(v_week.guest_judge_name), '') is null then 0 else 1 end;
  if coalesce(cardinality(p_eliminated_partnership_ids), 0) <> v_expected_eliminations then
    raise exception 'Choose exactly % eliminated couple(s) before completing this week.', v_expected_eliminations;
  end if;
  if (select count(distinct partnership_id) from unnest(p_eliminated_partnership_ids) as chosen(partnership_id)) <> v_expected_eliminations then
    raise exception 'Each eliminated couple must be different.';
  end if;
  if exists (
    select 1 from unnest(p_eliminated_partnership_ids) as chosen(partnership_id)
    where not exists (
      select 1 from public.dances as d where d.week_id = p_week_id
        and d.kind = 'competitive' and d.partnership_id = chosen.partnership_id
    )
  ) then raise exception 'An eliminated couple must have a competitive dance recorded in that week.'; end if;
  if exists (
    select 1 from public.dances as d where d.week_id = p_week_id and d.kind = 'competitive'
      and (select count(*) from public.dance_judge_scores as s where s.dance_id = d.id) <> v_expected_judges
  ) then raise exception 'Every competitive dance needs exactly % judge score(s) before completion.', v_expected_judges; end if;

  insert into public.weekly_roster_snapshots (
    week_id, cast_member_id, fantasy_team_id, cast_member_name, cast_role, manager_name, team_name, appearance_points
  )
  select p_week_id, c.id, c.fantasy_team_id, c.name,
    case
      when c.eliminated_week_id = p_week_id and c.role = 'Eliminated Star' then 'Star'
      when c.eliminated_week_id = p_week_id and c.role = 'Eliminated Pro' then 'Pro'
      else c.role
    end,
    t.manager_name, t.team_name,
    case when c.role = 'Surprise' then c.custom_appearance_points else null end
  from public.cast_members as c
  left join public.fantasy_teams as t on t.id = c.fantasy_team_id
  on conflict (week_id, cast_member_id) do update set
    fantasy_team_id = excluded.fantasy_team_id,
    cast_member_name = excluded.cast_member_name,
    cast_role = excluded.cast_role,
    manager_name = excluded.manager_name,
    team_name = excluded.team_name,
    appearance_points = excluded.appearance_points;

  insert into public.weekly_role_rates (week_id, role, appearance_points)
  select p_week_id, r.name, r.appearance_points
  from public.roles as r where r.name <> 'Surprise'
  on conflict (week_id, role) do nothing;

  update public.cast_members as c set role = 'Eliminated Star', eliminated_week_id = p_week_id
  from public.partnerships as pair where pair.id = any(p_eliminated_partnership_ids) and c.id = pair.star_id;
  update public.cast_members as c set role = 'Eliminated Pro', eliminated_week_id = p_week_id
  from public.partnerships as pair where pair.id = any(p_eliminated_partnership_ids) and c.id = pair.pro_id;
  update public.weeks set is_complete = true where id = p_week_id;
end;
$$;

commit;
