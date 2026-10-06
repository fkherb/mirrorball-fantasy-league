-- TEST ONLY: run in the same isolated database AFTER dwts-automation.sql.
create or replace function pg_temp.check_true(condition boolean,message text) returns void language plpgsql as $$ begin
  if condition is distinct from true then raise exception 'TEST FAILED: %',message; end if;
end $$;
do $$ declare w uuid; d uuid; task jsonb; result jsonb; old_run uuid; p jsonb; caught boolean;
begin
  perform pg_temp.check_true(not has_function_privilege('anon','public.claim_dwts_work(text)','execute'),'anonymous cannot claim');
  perform pg_temp.check_true(not has_function_privilege('authenticated','public.report_dwts_work(text,uuid,jsonb)','execute'),'website cannot report');
  perform pg_temp.check_true(has_function_privilege('service_role','public.claim_dwts_work(text)','execute'),'worker backend can claim');
  insert into public.weeks(number,air_date,air_start_time,air_end_time)
    values(5,(now() at time zone 'America/New_York')::date,
      ((now() at time zone 'America/New_York')-interval '1 hour')::time,
      ((now() at time zone 'America/New_York')+interval '10 minutes')::time) returning id into w;
  perform pg_temp.check_true((select enabled from public.dwts_automation_weeks where week_id=w),'next week inherited automation');
  insert into public.dances(week_id,kind,partnership_id) select w,'competitive',id from public.partnerships limit 1 returning id into d;
  perform public.configure_dwts_automation(5,true,array['pre-show']);
  update public.dwts_automation_weeks set wiki_tag='#Week_5:_Test' where week_id=w;
  task:=public.claim_dwts_work('test-server');
  p:=jsonb_build_object('mode','pre-show','week',5,'week_tag','#Week_5:_Test','couples',jsonb_build_array(jsonb_build_object(
    'star_name',task->'targets'->0->>'star_name','pro_name',task->'targets'->0->>'pro_name','found',true,
    'performances','[{"dance":"Jive","song":"Test song","artist":null}]'::jsonb)));
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,p);
  perform public.configure_dwts_automation(5,true,array['pre-show']); task:=public.claim_dwts_work('test-server');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,'{"error":"Temporary Wiki failure"}');
  perform pg_temp.check_true((select matching_checks=0 from public.dance_confirmation_checks where dance_id=d and field_name='song'),'failed check breaks consecutive observations');
  perform public.configure_dwts_automation(5,true,array['pre-show']); task:=public.claim_dwts_work('test-server');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,p);
  perform pg_temp.check_true((select not song_confirmed from public.dances where id=d),'one successful check after missing data not enough');
  perform public.configure_dwts_automation(5,true,array['live-show']); task:=public.claim_dwts_work('test-server');
  p:=jsonb_set(p,'{mode}','"live-show"');
  p:=jsonb_set(p,'{couples,0,performances}','[{"scores":[7,6,7],"total":99}]');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,p);
  perform pg_temp.check_true(jsonb_array_length(result->'errors')=1,'bad total rejected');
  perform pg_temp.check_true(not exists(select 1 from public.dance_judge_scores where dance_id=d),'bad score data not stored');
  insert into public.dance_judge_scores(dance_id,judge_name,score) values(d,'Carrie Ann',7);
  perform public.configure_dwts_automation(5,true,array['live-show']); task:=public.claim_dwts_work('test-server');
  p:=jsonb_set(p,'{couples,0,performances}','[{"scores":[8,6,7],"total":21}]');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,p);
  perform pg_temp.check_true(jsonb_array_length(result->'errors')=1,'manual score conflict surfaced');
  perform pg_temp.check_true((select score=7 and confirmed from public.dance_judge_scores where dance_id=d and judge_name='Carrie Ann'),'manual score preserved');
  perform public.configure_dwts_automation(5,true,array['photos']); task:=public.claim_dwts_work('test-server');
  old_run:=(task->>'run_id')::uuid;
  perform pg_temp.check_true(public.claim_dwts_work('other-server')->>'run_id' is null,'active photo lease exclusive');
  caught:=false;
  begin
    perform public.report_dwts_work('test-server',old_run,'{"week":5,"dry_run":true,"uploaded_couples":[]}');
  exception when others then caught:=position('Dry-run' in sqlerrm)>0; end;
  perform pg_temp.check_true(caught,'dry-run report cannot mark uploads');
  update public.dwts_automation_jobs set lease_until=now()-interval '1 second' where active_run_id=old_run;
  caught:=false;
  begin
    perform public.report_dwts_work('test-server',old_run,'{"week":5,"dry_run":false,"uploaded_couples":[]}');
  exception when others then caught:=position('lease expired' in sqlerrm)>0; end;
  perform pg_temp.check_true(caught,'expired report rejected');
  task:=public.claim_dwts_work('test-server');
  perform pg_temp.check_true(task->>'run_id' is not null and (task->>'run_id')::uuid<>old_run,'expired job recovered');
  perform pg_temp.check_true((select status='expired' from public.dwts_automation_runs where id=old_run),'old run marked expired');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,'{"week":5,"dry_run":false,"uploaded_couples":[]}');
  perform pg_temp.check_true((select not photos_uploaded from public.dances where id=d),'empty upload list not success');
  insert into public.weeks(number) values(6);
  perform public.configure_dwts_automation(6,false,array['pre-show']);
  update public.weeks set is_complete=true where id=w;
  perform pg_temp.check_true(not (select enabled from public.dwts_automation_weeks a join public.weeks w on w.id=a.week_id where w.number=6),'explicit next-week pause preserved');
  perform pg_temp.check_true(public.dwts_window_opening(w,'photos','2020-01-01 00:00:00Z') is not null,'future window scheduled');
  perform pg_temp.check_true(public.dwts_window_opening(w,'photos','2099-01-01 00:00:00Z') is null,'expired windows never replayed');
end $$;
select 'PASS: privileges, inheritance, missing checks, invalid scores, manual conflicts, exclusive leases, dry runs, expiry recovery, explicit pauses, airing cutoffs' as tests;
