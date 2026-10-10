-- Run the ENTIRE file in Supabase SQL Editor after the existing automation,
-- worker-support, Score Desk controls and wiki-score-order migrations.
-- Safe to rerun. Existing dances, manual details and completed weeks stay intact.
-- Week 5 is repaired immediately and its pre-show imports enabled/woken below.
begin;

-- Serialize repair calls for a week. Never impose a unique couple constraint:
-- later episodes can legitimately give one couple multiple competitive dances.
create or replace function public.ensure_week_competitive_dances(p_week_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w public.weeks%rowtype; previous public.weeks%rowtype;
  rows jsonb; old_marker text;
begin
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-week-dances:'||p_week_id::text,0));
  select * into w from public.weeks where id=p_week_id for update;
  if not found or w.is_complete then return '[]'::jsonb; end if;
  select * into previous from public.weeks where number=w.number-1;
  if not found or not previous.is_complete or previous.is_season_finale then return '[]'::jsonb; end if;
  old_marker:=coalesce(current_setting('mirrorball.automation_import',true),'');
  perform set_config('mirrorball.automation_import','on',true);
  with eligible as (
    select p.id, row_number() over(order by s.name,r.name,p.id) as position
    from public.partnerships p
    join public.cast_members s on s.id=p.star_id
    join public.cast_members r on r.id=p.pro_id
    where p.active and s.role='Star' and r.role='Pro'
      and s.eliminated_week_id is null and r.eliminated_week_id is null
      and not exists(select 1 from public.dances d
        where d.week_id=w.id and d.kind='competitive' and d.partnership_id=p.id)
  ), inserted as (
    insert into public.dances(week_id,kind,partnership_id,sort_order)
    select w.id,'competitive',e.id,
      (select greatest(coalesce(max(sort_order),0),0) from public.dances where week_id=w.id)+e.position::integer
    from eligible e order by e.position
    returning id,kind,partnership_id,name,dance_type,song,sort_order
  ) select coalesce(jsonb_agg(to_jsonb(i) order by i.sort_order),'[]'::jsonb) into rows from inserted i;
  perform set_config('mirrorball.automation_import',old_marker,true);
  return rows;
end $$;

-- Website repair/retry uses the SAME database operation as the triggers.
create or replace function public.prepare_week_competitive_dances(p_week_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not coalesce(public.is_platform_admin(),false) then raise exception 'Platform-owner access required'; end if;
  perform public.ensure_week_competitive_dances(p_week_id);
  return coalesce((select jsonb_agg(to_jsonb(d) order by d.sort_order,d.id)
    from public.dances d where d.week_id=p_week_id and d.kind='competitive'),'[]'::jsonb);
end $$;

-- Deferred until transaction end so elimination changes are final even when an
-- app updates is_complete before updating the eliminated cast in that transaction.
create or replace function public.create_next_week_competitive_dances()
returns trigger language plpgsql security definer set search_path = '' as $$
declare upcoming uuid;
begin
  if tg_op='UPDATE' and new.is_complete is not distinct from old.is_complete then return null; end if;
  perform public.ensure_week_competitive_dances(new.id);
  select id into upcoming from public.weeks where number=new.number+1;
  if upcoming is not null then perform public.ensure_week_competitive_dances(upcoming); end if;
  return null;
end $$;
drop trigger if exists create_next_week_competitive_dances on public.weeks;
create constraint trigger create_next_week_competitive_dances
  after insert or update on public.weeks deferrable initially deferred
  for each row execute function public.create_next_week_competitive_dances();

revoke all on function public.ensure_week_competitive_dances(uuid),
  public.create_next_week_competitive_dances(),public.prepare_week_competitive_dances(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.prepare_week_competitive_dances(uuid) to authenticated;

-- Missing/not-yet-posted arrays must not crash a whole report or its score-order
-- wrapper. Preserve the installed importer, including any previous hotfixes.
create or replace function public.dwts_array_length(p_value jsonb)
returns integer language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_value)='array' then jsonb_array_length(p_value) else 0 end;
$$;
revoke all on function public.dwts_array_length(jsonb) from public,anon,authenticated,service_role;
do $$ declare f record; definition text; begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in
      ('report_dwts_work','report_dwts_work_base','report_dwts_work_before_photo_diagnostics')
      and pg_get_function_identity_arguments(p.oid)='p_worker text, p_run uuid, p_result jsonb'
  loop
    definition:=pg_get_functiondef(f.oid);
    if position('jsonb_array_length(' in definition)>0 then
      execute replace(definition,'jsonb_array_length(','public.dwts_array_length(');
    end if;
  end loop;
end $$;

-- Add diagnostics AROUND the existing importer; do not replace two-observation
-- confirmation, manual-edit protection, leases, or wiki-arrival ordering.
do $$ begin
  if to_regprocedure('public.report_dwts_work_before_photo_diagnostics(text,uuid,jsonb)') is null then
    alter function public.report_dwts_work(text,uuid,jsonb) rename to report_dwts_work_before_photo_diagnostics;
  end if;
end $$;
create or replace function public.report_dwts_work(p_worker text,p_run uuid,p_result jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  result:=public.report_dwts_work_before_photo_diagnostics(p_worker,p_run,p_result);
  if result->>'mode'='photos' and not coalesce((result->>'already_reported')::boolean,false)
    and jsonb_typeof(p_result->'diagnostics')='object'
    and octet_length((p_result->'diagnostics')::text)<=20000 then
    result:=result||jsonb_build_object('photo_diagnostics',p_result->'diagnostics');
    update public.dwts_automation_runs set summary=result where id=p_run;
  end if;
  return result;
end $$;
revoke all on function public.report_dwts_work_before_photo_diagnostics(text,uuid,jsonb),
  public.report_dwts_work(text,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.report_dwts_work(text,uuid,jsonb) to service_role;

create or replace function public.get_week_automation_status(p_week_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w public.weeks%rowtype; data jsonb;
begin
  if not coalesce(public.is_platform_admin(),false) then raise exception 'Platform-owner access required'; end if;
  select * into w from public.weeks where id=p_week_id;
  if not found then raise exception 'Week not found'; end if;
  select jsonb_build_object('settings',to_jsonb(a),'worker',to_jsonb(s),'server_time',now(),
    'previous_complete',w.number=1 or exists(select 1 from public.weeks p where p.number=w.number-1 and p.is_complete),
    'progress',(select jsonb_build_object('total',count(*),
      'dance_types',count(*) filter(where dance_type_confirmed),'songs',count(*) filter(where song_confirmed),
      'scores',count(*) filter(where scores_confirmed),'eliminations',count(*) filter(where elimination_confirmed),
      'photos',count(*) filter(where photos_uploaded)) from public.dances where week_id=w.id and kind='competitive'),
    'jobs',coalesce((select jsonb_agg(jsonb_build_object('mode',j.mode,'next_run_at',j.next_run_at,
      'lease_until',j.lease_until,'last_error',j.last_error,'pending',jsonb_array_length(public.dwts_pending_targets(w.id,j.mode)),
      'window',case when j.mode in ('photos','live-show','post-show') then public.dwts_window_opening(w.id,j.mode,now()) else now() end,
      'elimination_found',exists(select 1 from public.dances d where d.week_id=w.id and d.elimination_confirmed and d.elimination_result),
      'last_run',to_jsonb(r))) from public.dwts_automation_jobs j
      left join lateral (select started_at,finished_at,status,summary from public.dwts_automation_runs
        where job_id=j.id order by started_at desc limit 1) r on true
      where j.week_id=w.id),'[]'::jsonb)) into data
  from (select 1) seed left join public.dwts_automation_weeks a on a.week_id=w.id
    left join public.dwts_automation_state s on s.id=1;
  return data;
end $$;
revoke all on function public.get_week_automation_status(uuid) from public,anon;
grant execute on function public.get_week_automation_status(uuid) to authenticated;

-- Repair eligible upcoming weeks NOW (Week 5 after completed Week 4 included).
do $$ declare w record; begin
  for w in select upcoming.id from public.weeks upcoming join public.weeks previous
    on previous.number=upcoming.number-1
    where not upcoming.is_complete and previous.is_complete and not previous.is_season_finale
  loop perform public.ensure_week_competitive_dances(w.id); end loop;
end $$;

-- Explicit Week 5 recovery requested by the owner. Keep the wiki tag, judge
-- order, other selected job modes and outstanding leases. Enable dance-info
-- imports only; do not turn on retroactive photos or any additional modes.
update public.dwts_automation_weeks a set enabled=true,
  modes=case when 'pre-show'=any(a.modes) then a.modes else a.modes||array['pre-show'] end,
  updated_at=now()
from public.weeks w where a.week_id=w.id and w.number=5 and not w.is_complete;
insert into public.dwts_automation_jobs(week_id,mode)
  select a.week_id,'pre-show' from public.dwts_automation_weeks a join public.weeks w on w.id=a.week_id
  where w.number=5 and not w.is_complete
on conflict(week_id,mode) do update set next_run_at=now();

notify pgrst,'reload schema';
commit;

-- This should show Week 5's 11 competitive cards on the current live cast.
-- Confirmation counts start at zero and rise after the worker checks the wiki.
select w.number,count(d.id) as competitive_cards,
  count(d.id) filter(where d.dance_type_confirmed and d.song_confirmed) as confirmed_couples,
  a.enabled as automation_enabled,a.wiki_tag,a.modes
from public.weeks w left join public.dances d on d.week_id=w.id and d.kind='competitive'
  left join public.dwts_automation_weeks a on a.week_id=w.id
where w.number=5 group by w.number,a.enabled,a.wiki_tag,a.modes;
