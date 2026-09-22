-- RUN THIS ONCE in Supabase Dashboard → SQL Editor when you are back at a
-- computer. It is not applied by the website or by Codex.
--
-- This adds database-enforced Score Desk rules, a commissioner-editable
-- role-rate table, and a "Mark Complete" workflow with roster snapshots.

-- Preflight: BOTH result sets must be empty before continuing. If either has
-- rows, stop and resolve the listed data before running the migration.
select week_id, partnership_id, count(*) as competitive_dance_count
from public.dances
where kind = 'competitive'
group by week_id, partnership_id
having count(*) > 1;

select d.id as dance_id, c.name as cast_member, s.name as star, p.name as pro
from public.dance_appearances as a
join public.dances as d on d.id = a.dance_id and d.kind = 'competitive'
join public.partnerships as pair on pair.id = d.partnership_id
join public.cast_members as c on c.id = a.cast_member_id
join public.cast_members as s on s.id = pair.star_id
join public.cast_members as p on p.id = pair.pro_id
where a.cast_member_id in (pair.star_id, pair.pro_id);

begin;

alter table public.weeks add column if not exists is_finale boolean not null default false;
alter table public.weeks add column if not exists is_complete boolean not null default false;

create table if not exists public.weekly_roster_snapshots (
  week_id uuid not null references public.weeks(id) on delete cascade,
  cast_member_id uuid not null references public.cast_members(id) on delete restrict,
  fantasy_team_id uuid references public.fantasy_teams(id) on delete set null,
  cast_member_name text not null,
  cast_role text not null,
  manager_name text,
  team_name text,
  created_at timestamptz not null default now(),
  primary key (week_id, cast_member_id)
);
alter table public.weekly_roster_snapshots enable row level security;
grant select on public.weekly_roster_snapshots to anon, authenticated;
grant insert, update, delete on public.weekly_roster_snapshots to authenticated;
drop policy if exists "public read weekly roster snapshots" on public.weekly_roster_snapshots;
create policy "public read weekly roster snapshots"
  on public.weekly_roster_snapshots for select using (true);
drop policy if exists "commissioner writes weekly roster snapshots" on public.weekly_roster_snapshots;
create policy "commissioner writes weekly roster snapshots"
  on public.weekly_roster_snapshots for all to authenticated
  using ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com');

-- A competitive dance must name a couple; a performance must not.
alter table public.dances drop constraint if exists dances_kind_partnership_shape;
alter table public.dances add constraint dances_kind_partnership_shape
  check ((kind = 'competitive' and partnership_id is not null) or (kind = 'performance' and partnership_id is null)) not valid;
alter table public.dances validate constraint dances_kind_partnership_shape;

-- One regular competitive dance per couple per week.
create unique index if not exists one_competitive_dance_per_pair_per_week
  on public.dances (week_id, partnership_id) where kind = 'competitive';

-- A competing star or pro already receives the official score and may not also
-- receive an appearance award for that same dance.
create or replace function public.prevent_competing_pair_appearance()
returns trigger language plpgsql as $$
begin
  if exists (
    select 1 from public.dances as d
    join public.partnerships as pair on pair.id = d.partnership_id
    where d.id = new.dance_id and d.kind = 'competitive'
      and new.cast_member_id in (pair.star_id, pair.pro_id)
  ) then
    raise exception 'The competing couple cannot be added as a cast appearance.';
  end if;
  return new;
end;
$$;
drop trigger if exists prevent_competing_pair_appearance on public.dance_appearances;
create trigger prevent_competing_pair_appearance
before insert or update on public.dance_appearances
for each row execute function public.prevent_competing_pair_appearance();

-- Once completed, a week and its dances cannot be changed through the API.
create or replace function public.prevent_completed_week_edit()
returns trigger language plpgsql as $$
declare v_week_id uuid;
begin
  if tg_table_name = 'dances' then
    v_week_id := coalesce(new.week_id, old.week_id);
  else
    select week_id into v_week_id from public.dances
    where id = coalesce(new.dance_id, old.dance_id);
  end if;
  if exists (select 1 from public.weeks where id = v_week_id and is_complete) then
    raise exception 'This week is complete and its scoring is read-only.';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
drop trigger if exists prevent_completed_dance_edit on public.dances;
create trigger prevent_completed_dance_edit
before insert or update or delete on public.dances
for each row execute function public.prevent_completed_week_edit();
drop trigger if exists prevent_completed_judge_score_edit on public.dance_judge_scores;
create trigger prevent_completed_judge_score_edit
before insert or update or delete on public.dance_judge_scores
for each row execute function public.prevent_completed_week_edit();
drop trigger if exists prevent_completed_appearance_edit on public.dance_appearances;
create trigger prevent_completed_appearance_edit
before insert or update or delete on public.dance_appearances
for each row execute function public.prevent_completed_week_edit();

create or replace function public.prevent_completed_week_metadata_edit()
returns trigger language plpgsql as $$
begin
  if old.is_complete and new is distinct from old then
    raise exception 'This week is complete and its setup is read-only.';
  end if;
  return new;
end;
$$;
drop trigger if exists prevent_completed_week_metadata_edit on public.weeks;
create trigger prevent_completed_week_metadata_edit
before update on public.weeks
for each row execute function public.prevent_completed_week_metadata_edit();

-- This runs atomically: validation, the snapshot, role changes, and completion
-- all happen together, or none of them happen.
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
  ) then
    raise exception 'An eliminated couple must have a competitive dance recorded in that week.';
  end if;
  if exists (
    select 1 from public.dances as d where d.week_id = p_week_id and d.kind = 'competitive'
      and (select count(*) from public.dance_judge_scores as s where s.dance_id = d.id) <> v_expected_judges
  ) then
    raise exception 'Every competitive dance needs exactly % judge score(s) before completion.', v_expected_judges;
  end if;

  -- Snapshot the roster and role as they stood DURING this week, before the
  -- eliminated roles below take effect for following weeks.
  insert into public.weekly_roster_snapshots (
    week_id, cast_member_id, fantasy_team_id, cast_member_name, cast_role, manager_name, team_name
  )
  select p_week_id, c.id, c.fantasy_team_id, c.name,
    case
      when c.eliminated_week_id = p_week_id and c.role = 'Eliminated Star' then 'Star'
      when c.eliminated_week_id = p_week_id and c.role = 'Eliminated Pro' then 'Pro'
      else c.role
    end,
    t.manager_name, t.team_name
  from public.cast_members as c
  left join public.fantasy_teams as t on t.id = c.fantasy_team_id
  on conflict (week_id, cast_member_id) do update set
    fantasy_team_id = excluded.fantasy_team_id,
    cast_member_name = excluded.cast_member_name,
    cast_role = excluded.cast_role,
    manager_name = excluded.manager_name,
    team_name = excluded.team_name;

  update public.cast_members as c set role = 'Eliminated Star', eliminated_week_id = p_week_id
  from public.partnerships as pair
  where pair.id = any(p_eliminated_partnership_ids) and c.id = pair.star_id;
  update public.cast_members as c set role = 'Eliminated Pro', eliminated_week_id = p_week_id
  from public.partnerships as pair
  where pair.id = any(p_eliminated_partnership_ids) and c.id = pair.pro_id;
  update public.weeks set is_complete = true where id = p_week_id;
end;
$$;
grant execute on function public.complete_week(uuid, uuid[]) to authenticated;
revoke execute on function public.complete_week(uuid, uuid[]) from anon;

-- The public can read rates. Only the commissioner may change defaults.
grant update on public.roles to authenticated;
drop policy if exists "commissioner writes roles" on public.roles;
create policy "commissioner writes roles"
  on public.roles for update to authenticated
  using ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com');

commit;
