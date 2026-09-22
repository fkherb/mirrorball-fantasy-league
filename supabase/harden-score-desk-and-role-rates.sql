-- DO NOT RUN THIS YET.
-- This migration is prepared for the next time you are at Supabase. It has not
-- been applied by the website or by Codex.
--
-- It makes the database enforce the Score Desk rules that are currently only
-- protected by the browser, and lets the commissioner edit default role rates.

-- Preflight: both result sets must be empty before continuing.
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

-- A competitive dance must name a couple; a performance must not.
alter table public.dances
  drop constraint if exists dances_kind_partnership_shape;
alter table public.dances
  add constraint dances_kind_partnership_shape
  check (
    (kind = 'competitive' and partnership_id is not null)
    or (kind = 'performance' and partnership_id is null)
  ) not valid;
alter table public.dances
  validate constraint dances_kind_partnership_shape;

-- One regular competitive dance per couple per week.
create unique index if not exists one_competitive_dance_per_pair_per_week
  on public.dances (week_id, partnership_id)
  where kind = 'competitive';

-- A competing star or pro already receives the official score and may not also
-- receive an appearance award for the same dance.
create or replace function public.prevent_competing_pair_appearance()
returns trigger
language plpgsql
as $$
begin
  if exists (
    select 1
    from public.dances as d
    join public.partnerships as pair on pair.id = d.partnership_id
    where d.id = new.dance_id
      and d.kind = 'competitive'
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

-- The public can still read rates. Only the commissioner may change them.
grant update on public.roles to authenticated;
drop policy if exists "commissioner writes roles" on public.roles;
create policy "commissioner writes roles"
  on public.roles for update to authenticated
  using ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'herbfreddy@gmail.com');

commit;
