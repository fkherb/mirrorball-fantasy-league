-- TEST ONLY: fresh disposable fixture + all three migrations.
do $$ declare task jsonb; r uuid; target jsonb; response jsonb; caught boolean:=false; begin
  if has_function_privilege('authenticated','public.preview_dwts_work(integer,text,text)','execute') then raise exception 'Preview exposed'; end if;
  perform public.preview_dwts_work(4,'pre-show','#Week_4:_Test');
  if exists(select 1 from public.dwts_automation_runs) then raise exception 'Preview created a run'; end if;
  perform public.configure_dwts_automation(4,true,array['photos']);
  task:=public.claim_dwts_work('server'); r:=(task->>'run_id')::uuid;
  target:=task->'targets'->0;
  update public.dwts_automation_jobs set lease_until=now()-interval '1 minute' where active_run_id=r;
  perform public.heartbeat_dwts_worker('server',r);
  response:=public.reconcile_dwts_photos('server',r,jsonb_build_array(jsonb_build_object(
    'dance_id',target->>'dance_id','commit_sha',repeat('a',40),'files',jsonb_build_array(jsonb_build_object(
    'path',task->>'folder'||'/'||(target->>'star_name')||' and '||(target->>'pro_name')||'-1.avif')))));
  if jsonb_array_length(response->'verified_dance_ids')<>1 then raise exception 'Reconciliation failed'; end if;
  if exists(select 1 from public.dances where kind='performance' and photos_uploaded) then raise exception 'Performance modified'; end if;
  if exists(select 1 from public.dwts_photo_receipts) then raise exception 'Fabricated X receipt'; end if;
  begin perform public.heartbeat_dwts_worker('other-server',r); exception when others then caught:=true; end;
  if not caught then raise exception 'Another server renewed lease'; end if;
end $$;
select 'PASS: readonly previews, same-run restart renewal, worker isolation, manual GitHub photo reconciliation' as tests;
