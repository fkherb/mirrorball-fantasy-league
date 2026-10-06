-- Run once in Supabase SQL Editor. Draft performances may remain untitled and
-- have no cast, but both are required when their week is marked complete.
-- Competitive dances must have the full judge panel scored too.
begin;

create or replace function public.require_complete_performances_before_week_completion()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.dances d
    where d.week_id = new.id and d.kind = 'performance'
      and nullif(btrim(d.name), '') is null
  ) then
    raise exception 'Every performance dance needs a title before week completion.';
  end if;

  if exists (
    select 1 from public.dances d
    where d.week_id = new.id and d.kind = 'performance'
      and not exists (
        select 1 from public.dance_appearances a where a.dance_id = d.id
      )
  ) then
    raise exception 'Every performance dance needs at least one cast member before week completion.';
  end if;

  if exists (
    select 1 from public.dances d
    where d.week_id = new.id and d.kind = 'competitive'
      and (
        select count(*) from public.dance_judge_scores s where s.dance_id = d.id
      ) <> 3 + case when nullif(btrim(new.guest_judge_name), '') is null then 0 else 1 end
  ) then
    raise exception 'Every competitive dance needs all judge scores before week completion.';
  end if;

  return new;
end;
$$;

drop trigger if exists require_complete_performances_before_week_completion on public.weeks;
create trigger require_complete_performances_before_week_completion
before update of is_complete on public.weeks
for each row
when (new.is_complete and not old.is_complete)
execute function public.require_complete_performances_before_week_completion();

commit;
