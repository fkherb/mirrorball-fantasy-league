-- TEST ONLY: fresh fixture + migrations + score-desk dependency fixture.
do $$ declare w uuid; setup jsonb; options jsonb; status jsonb; caught boolean:=false; begin
  select id into w from public.weeks where number=4;
  setup:=jsonb_build_object('p_week_id',w,'p_title','Saved title','p_guest_judge_name',null,'p_dance_ids','[]'::jsonb);
  options:='{"enabled":true,"modes":["get-weeks","pre-show","photos"],"wiki_tag_override":false,"judge_order":null}';
  begin perform public.save_week_with_automation(setup,options); exception when others then caught:=position('Platform-owner' in sqlerrm)>0; end;
  if not caught then raise exception 'Non-owner saved settings'; end if;
  perform set_config('test.owner','yes',true);
  perform public.save_week_with_automation(setup,options);
  status:=public.get_week_automation_status(w);
  if not (status->'settings'->>'enabled')::boolean or (status->'progress'->>'total')::integer<>2 then raise exception 'Status/settings mismatch'; end if;
  options:=jsonb_set(options,'{wiki_tag_override}','true'); options:=jsonb_set(options,'{wiki_tag}','"#Week_4:_Test"');
  perform public.save_week_with_automation(setup,options);
  if (select wiki_tag from public.dwts_automation_weeks where week_id=w)<>'#Week_4:_Test' then raise exception 'Override not saved'; end if;
  options:=jsonb_set(options,'{wiki_tag_override}','false');
  perform public.save_week_with_automation(setup,options);
  if (select wiki_tag from public.dwts_automation_weeks where week_id=w) is not null then raise exception 'Auto discovery not reset'; end if;
  setup:=jsonb_set(setup,'{p_guest_judge_name}','"Guest"'); options:=jsonb_set(options,'{modes}','["live-show"]'); caught:=false;
  begin perform public.save_week_with_automation(setup,options); exception when others then caught:=position('judge order' in sqlerrm)>0; end;
  if not caught then raise exception 'Missing guest order accepted'; end if;
  if (select guest_judge_name from public.weeks where id=w) is not null then raise exception 'Partial save leaked'; end if;
  options:=jsonb_set(options,'{judge_order}','["Carrie Ann","Guest","Derek","Bruno"]');
  perform public.save_week_with_automation(setup,options);
  setup:=jsonb_set(setup,'{p_title}','"force rollback"'); caught:=false;
  begin perform public.save_week_with_automation(setup,options); exception when others then caught:=true; end;
  if not caught or (select title from public.weeks where id=w)<>'Saved title' then raise exception 'Atomic rollback failed'; end if;
  if has_function_privilege('anon','public.save_week_with_automation(jsonb,jsonb)','execute') then raise exception 'Anonymous access exposed'; end if;
end $$;
select 'PASS: owner-only settings, status counts, manual tag/reset, guest order validation and atomic rollback' as tests;
