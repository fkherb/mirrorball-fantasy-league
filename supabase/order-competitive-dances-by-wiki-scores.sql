-- Run once after add-dwts-automation-functions.sql. The existing Mac worker can
-- continue reporting normally; update dwts-wiki.py on the Mac for wiki-row ties.
-- First-seen scores set the provisional show order. A manual Score Desk reorder
-- stops further automatic ordering for that week.
begin;

alter table public.weeks
  add column if not exists dance_order_manually_set boolean not null default false;
alter table public.dances
  add column if not exists wiki_score_sequence integer;

create or replace function public.mark_manual_dance_order()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.sort_order is distinct from old.sort_order
    and current_setting('mirrorball.automation_import',true) is distinct from 'on' then
    update public.weeks set dance_order_manually_set = true where id = new.week_id;
  end if;
  return null;
end $$;
drop trigger if exists mark_manual_dance_order on public.dances;
create trigger mark_manual_dance_order after update of sort_order on public.dances
  for each row execute function public.mark_manual_dance_order();

-- Wrap the existing importer so its validation and two-check score confirmation
-- remain unchanged. Only a successful first score observation changes order.
do $$ begin
  if to_regprocedure('public.report_dwts_work_base(text,uuid,jsonb)') is null then
    alter function public.report_dwts_work(text,uuid,jsonb) rename to report_dwts_work_base;
  end if;
end $$;

create or replace function public.report_dwts_work(p_worker text,p_run uuid,p_result jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  result jsonb;
  run_row public.dwts_automation_runs%rowtype;
  v_week_id uuid;
  candidate record;
  next_sequence integer;
  previous_setting text;
  observed boolean := false;
begin
  result := public.report_dwts_work_base(p_worker,p_run,p_result);
  if p_result->>'mode' is distinct from 'live-show'
    or coalesce((result->>'already_reported')::boolean,false)
    or coalesce((p_result->>'failed_run')::boolean,false)
    or p_result ? 'error' then return result; end if;

  select * into run_row from public.dwts_automation_runs where id = p_run;
  select j.week_id into v_week_id from public.dwts_automation_jobs j where j.id = run_row.job_id;
  if not exists (select 1 from public.weeks w
    where w.id = v_week_id and not w.is_complete and not w.dance_order_manually_set) then
    return result;
  end if;

  -- The importer has already authenticated the worker and accepted this run.
  -- Match only couples in its claimed payload; never trust extra JSON couples.
  for candidate in
    select d.id, coalesce(nullif(c.perf->>'table_index','')::integer,2147483647) as table_index,
      coalesce(nullif(c.perf->>'row_index','')::integer,2147483647) as row_index,
      t->>'star_name' as star_name
    from jsonb_array_elements(run_row.payload->'targets') t
    join public.dances d on d.id = (t->>'dance_id')::uuid and d.week_id = v_week_id
      and d.kind = 'competitive' and d.wiki_score_sequence is null
    cross join lateral (
      select item->'performances'->0 as perf
      from jsonb_array_elements(coalesce(p_result->'couples','[]'::jsonb)) item
      where item->>'star_name' = t->>'star_name'
        and item->>'pro_name' = t->>'pro_name'
        and item->>'found' = 'true'
        and jsonb_typeof(item->'performances') = 'array'
        and jsonb_array_length(item->'performances') = 1
      limit 1
    ) c
    where jsonb_typeof(c.perf->'scores') = 'array'
      and jsonb_array_length(c.perf->'scores') in (3,4)
      and exists (select 1 from public.dance_judge_scores s where s.dance_id = d.id)
      and not exists (select 1 from jsonb_array_elements(coalesce(result->'errors','[]'::jsonb)) e
        where e->>'dance_id' = d.id::text)
    order by table_index,row_index,star_name,d.id
  loop
    select coalesce(max(wiki_score_sequence),0)+1 into next_sequence
      from public.dances where week_id = v_week_id;
    update public.dances set wiki_score_sequence = next_sequence where id = candidate.id;
    observed := true;
  end loop;

  if not observed then return result; end if;
  previous_setting := coalesce(current_setting('mirrorball.automation_import',true),'');
  perform set_config('mirrorball.automation_import','on',true);
  -- Keep performance tiles in their existing slots. Only competitive slots
  -- change: scored couples first, then unscored couples alphabetically.
  with slots as (
    select d.sort_order, row_number() over (order by d.sort_order,d.id) as position
    from public.dances d where d.week_id = v_week_id and d.kind = 'competitive'
  ), ranked as (
    select d.id, row_number() over (order by d.wiki_score_sequence nulls last,
      s.name collate "C",d.id) as position
    from public.dances d
    join public.partnerships p on p.id = d.partnership_id
    join public.cast_members s on s.id = p.star_id
    where d.week_id = v_week_id and d.kind = 'competitive'
  )
  update public.dances d set sort_order = slots.sort_order
    from ranked join slots on slots.position = ranked.position
    where d.id = ranked.id and d.sort_order is distinct from slots.sort_order;
  perform set_config('mirrorball.automation_import',previous_setting,true);
  return result;
end $$;

revoke all on function public.report_dwts_work_base(text,uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.report_dwts_work(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.report_dwts_work(text,uuid,jsonb) to service_role;

commit;
