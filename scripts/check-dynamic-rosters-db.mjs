// Real PostgreSQL integration test. NEVER accepts a live database URL.
// Usage: node scripts/check-dynamic-rosters-db.mjs mirrorball-roster-test-20261008
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { calculateRosterLimits, rosterExchangeIssue, draftCategoryEligibility } from '../roster-rules.js';
const container=process.argv[2];
assert.match(container || '',/^mirrorball-roster-test-\d{8}$/,'Use an explicitly named disposable test container.');
for (const command of ['dropdb','createdb']) {
  const result=spawnSync('docker',['exec',container,command,'-U','supabase_admin',
    ...(command==='dropdb'?['--if-exists']:[]),'mirrorball_roster_tests'],{encoding:'utf8'});
  if(result.status!==0)throw Error(result.stderr);
}
const query=(sql)=>{
  const result=spawnSync('docker',['exec','-i',container,'psql','-U','supabase_admin','-d','mirrorball_roster_tests','-X','-qAt','-v','ON_ERROR_STOP=1'],{input:sql,encoding:'utf8',maxBuffer:8*1024*1024});
  if(result.status!==0)throw Error(result.stderr || result.error?.message);
  return result.stdout.trim();
};
const fixture=await readFile(new URL('./tests/dynamic-rosters-fixture.sql',import.meta.url),'utf8');
const migration=await readFile(new URL('../supabase/dynamic-roster-limits.sql',import.meta.url),'utf8');
const verify=await readFile(new URL('../supabase/check-dynamic-roster-limits.sql',import.meta.url),'utf8');
const league='00000000-0000-4000-8000-000000000010';
const uuid=i=>`00000000-0000-4000-8000-${String(i).padStart(12,'0')}`;
query(fixture+`
  insert into public.leagues(id,status,roster_size) values('${league}','drafting',10);
  insert into public.fantasy_teams select ('00000000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'${league}' from generate_series(101,104) i;
  insert into public.league_members select '${league}',id,id,'active' from public.fantasy_teams;
  insert into public.cast_members select ('00000000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,case when i<=11 then 'Pro' when i<=22 then 'Star' else 'Troupe' end from generate_series(1,44) i;
  update public.leagues set draft_cast_roles=(select jsonb_object_agg(id::text,role) from public.cast_members);
`+'\n'+migration+'\n'+migration);
const legacyLimits=JSON.parse(query(`select public.league_roster_limits('${league}');`));
assert.equal(legacyLimits.active_max,5);assert.equal(legacyLimits.legacy_draft_limits,true);
const seed=(couples,teamCount,size)=>query(`
  truncate public.league_trade_offers,public.league_roster_assignments,public.league_draft_order,public.league_members,public.fantasy_teams,public.leagues,public.cast_members;
  insert into public.leagues(id,status,roster_size) values('${league}','setup',${size});
  insert into public.fantasy_teams select ('00000000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'${league}' from generate_series(101,${100+teamCount}) i;
  insert into public.league_members select '${league}',id,id,'active' from public.fantasy_teams;
  insert into public.cast_members select ('00000000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,case when i<=${couples} then 'Pro' when i<=${2*couples} then 'Star' else 'Troupe' end from generate_series(201,244) j cross join lateral (select j-200 as i) s;
`);
// cast UUIDs deliberately use 1..44, team UUIDs use 101..105.
let cases=0;
for(const [n,size] of [[3,12],[4,10],[5,8]]) for(let c=16;c>=4;c--) {
  seed(c,n,size);
  const expected=calculateRosterLimits(c,c,n,size);
  const actual=JSON.parse(query(`select public.league_roster_limits('${league}');`));
  for(const key of Object.keys(expected))assert.equal(actual[key],expected[key]);
  assert.equal(query(`select public.league_draft_can_finish('${league}');`),'t');
  query(`update public.leagues set status='drafting' where id='${league}';`);
  // Draft every slot through the actual insert trigger and SQL auto picker.
  query(`do $$ declare r int;p int;t uuid;c uuid;begin
    for r in 0..${size-1} loop for p in 1..${n} loop
      t:=('00000000-0000-4000-8000-'||lpad((100+case when r%2=0 then p else ${n}+1-p end)::text,12,'0'))::uuid;
      c:=public.choose_ordered_random_draft_cast('${league}',t);
      if c is null then raise exception 'Draft stranded';end if;
      insert into public.league_roster_assignments(league_id,cast_member_id,fantasy_team_id) values('${league}',c,t);
    end loop;end loop;end $$;`);
  assert.equal(Number(query('select count(*) from public.league_roster_assignments;')),n*size);
  cases++;
}
// Exhaustive SQL/JS parity for corrective exchanges, including partial fixes.
seed(11,4,10);
const limits=calculateRosterLimits(11,11,4,10);
const checks=[];
for(let p=0;p<=6;p++)for(let s=0;s<=6;s++) {
  const b=10-p-s;if(b<0)continue;
  const counts={Pro:p,Star:s,Bonus:b};
  for(const out of ['Pro','Star','Bonus'])for(const incoming of ['Pro','Star','Bonus'])
    checks.push({counts,out,incoming,expected:rosterExchangeIssue(counts,limits,out,incoming)||null});
}
const results=query(checks.map((v,i)=>`select ${i},to_json(public.roster_exchange_issue('${JSON.stringify(v.counts)}','${JSON.stringify(limits)}','${v.out}','${v.incoming}'));`).join('\n')).split('\n');
for(const line of results) {const [index,value]=line.split('|');assert.equal(value ? JSON.parse(value):null,checks[Number(index)].expected);}
// Valid Bonus->active swap; no sign-in, active offer, and airing rejection.
query(`insert into public.league_roster_assignments(league_id,cast_member_id,fantasy_team_id)
 select '${league}',id,'${uuid(101)}' from public.cast_members where id in (${[1,2,12,13,23,24,25,26,27,28].map(i=>`'${uuid(i)}'`).join(',')});
 update public.leagues set status='active' where id='${league}';`);
assert.throws(()=>query(`select public.claim_league_cast_member('${league}','${uuid(3)}','${uuid(23)}');`),/Sign in/);
query(`set test.user_id='${uuid(101)}';select public.claim_league_cast_member('${league}','${uuid(3)}','${uuid(23)}');`);
assert.equal(query(`select public.league_roster_counts('${league}','${uuid(101)}');`),'\{"Pro": 3, "Star": 2, "Bonus": 5\}');
assert.throws(()=>query(`set test.user_id='${uuid(101)}';set test.airing_locked='on';select public.claim_league_cast_member('${league}','${uuid(4)}','${uuid(24)}');`),/paused from airtime/);
const rules=JSON.parse(query(`set test.user_id='${uuid(101)}';select public.get_league_roster_rules('${league}');`));
assert.equal(rules.version,1);assert.equal(rules.limits.active_max,6);
assert.equal(query(`select has_function_privilege('authenticated','public.get_league_roster_rules(uuid)','EXECUTE');`),'t');
assert.equal(query(`select has_function_privilege('authenticated','public.league_draft_can_finish(uuid,uuid,text)','EXECUTE');`),'f');
// A partial corrective swap is valid even though the Pro count stays above 3.
seed(11,4,10);
query(`insert into public.league_roster_assignments(league_id,cast_member_id,fantasy_team_id)
 select '${league}',id,'${uuid(101)}' from public.cast_members where id in (${[1,2,3,4,5,12,23,24,25,26].map(i=>`'${uuid(i)}'`).join(',')});
 update public.leagues set status='active' where id='${league}';
 set test.user_id='${uuid(101)}';select public.claim_league_cast_member('${league}','${uuid(27)}','${uuid(1)}');`);
assert.equal(JSON.parse(query(`select public.league_roster_counts('${league}','${uuid(101)}');`)).Pro,4);
assert.throws(()=>query(`set test.user_id='${uuid(101)}';select public.claim_league_cast_member('${league}','${uuid(13)}','${uuid(12)}');`),/over-limit category/);
// Real two-row atomic trade, offer/counter checks, and acceptance revalidation.
const seedTrade=()=>{
  seed(11,4,10);
  query(`insert into public.league_roster_assignments(league_id,cast_member_id,fantasy_team_id)
    select '${league}',id,case when id in (${[1,2,3,12,13,23,24,25,26,27].map(i=>`'${uuid(i)}'`).join(',')}) then '${uuid(101)}'::uuid else '${uuid(102)}'::uuid end
    from public.cast_members where id in (${[1,2,3,12,13,23,24,25,26,27,4,5,14,15,16,28,29,30,31,32].map(i=>`'${uuid(i)}'`).join(',')});
    update public.leagues set status='active' where id='${league}';
    insert into public.league_trade_offers(league_id,initiator_team_id,counterparty_team_id,initiator_cast_member_id,counterparty_cast_member_id)
    values('${league}','${uuid(101)}','${uuid(102)}','${uuid(1)}','${uuid(14)}');`);
};
const acceptTrade=`update public.league_roster_assignments set fantasy_team_id=case when cast_member_id='${uuid(1)}' then '${uuid(102)}'::uuid else '${uuid(101)}'::uuid end where cast_member_id in ('${uuid(1)}','${uuid(14)}');`;
seedTrade();
assert.throws(()=>query(`update public.league_trade_offers set counterparty_cast_member_id='${uuid(28)}';`),/Bonus limit/);
query(acceptTrade);
assert.deepEqual(JSON.parse(query(`select public.league_roster_counts('${league}','${uuid(101)}');`)),{Pro:2,Star:3,Bonus:5});
seedTrade();
query(`update public.cast_members set role='Eliminated Pro' where id='${uuid(1)}';`);
assert.throws(()=>query(acceptTrade),/Bonus limit|over-limit category/);
assert.equal(query(`select fantasy_team_id from public.league_roster_assignments where cast_member_id='${uuid(1)}';`),uuid(101),'A rejected acceptance must roll back both transfers.');
// Deleted managers must not inflate limits; blank never-drafted orphan teams
// must not become new roster obligations. Keep actual retained participants.
query(`delete from public.league_members where fantasy_team_id='${uuid(102)}';
 insert into public.fantasy_teams values('${uuid(105)}','${league}');`);
assert.equal(JSON.parse(query(`select public.league_roster_limits('${league}');`)).team_count,4);
// Role edits during a draft must not change its counts or limits.
seed(11,4,10);
query(`update public.leagues set status='drafting' where id='${league}';update public.cast_members set role='Eliminated Pro' where id='${uuid(1)}';`);
assert.equal(query(`select public.league_draft_role('${league}','${uuid(1)}');`),'Pro');
assert.equal(JSON.parse(query(`select public.league_roster_limits('${league}');`)).active_max,6);
const eligibility=JSON.parse(query(`set test.user_id='${uuid(101)}';select public.get_league_roster_rules('${league}');`)).teams[0].draft_eligible_categories;
assert.deepEqual(eligibility,draftCategoryEligibility({Pro:11,Star:11,Bonus:22},Array.from({length:4},()=>({Pro:0,Star:0,Bonus:0})),0,limits));
// Original league bypasses every cap, including active insert restrictions.
query(`insert into public.leagues(id,status,roster_size) values(public.default_fantasy_league_id(),'active',1);
 insert into public.fantasy_teams values('${uuid(151)}',public.default_fantasy_league_id()),('${uuid(152)}',public.default_fantasy_league_id());
 insert into public.league_members values(public.default_fantasy_league_id(),'${uuid(151)}','${uuid(151)}','active');
 insert into public.league_roster_assignments(league_id,cast_member_id,fantasy_team_id)
 select public.default_fantasy_league_id(),id,case when id<'${uuid(23)}' then '${uuid(151)}'::uuid else '${uuid(152)}'::uuid end from public.cast_members;
 update public.league_roster_assignments set fantasy_team_id=case when cast_member_id='${uuid(1)}' then '${uuid(152)}'::uuid else '${uuid(151)}'::uuid end where league_id=public.default_fantasy_league_id() and cast_member_id in ('${uuid(1)}','${uuid(23)}');`);
assert.equal(JSON.parse(query(`set test.user_id='${uuid(151)}';select public.get_league_roster_rules(public.default_fantasy_league_id());`)).limits.exempt,true);
query(verify);
console.log(`${cases} PostgreSQL snake drafts, ${checks.length} SQL/JS exchange comparisons, migration rerun, atomic trades/counters, acceptance rechecks, partial corrections, orphan/default exemptions and frozen drafts verified.`);
