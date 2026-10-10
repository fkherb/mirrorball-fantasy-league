// Real PostgreSQL regression tests; NEVER accepts a live URL or credentials.
// Usage: node scripts/check-week-automation-db.mjs mirrorball-automation-test-20261009
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
const container = process.argv[2];
assert.match(container || '', /^mirrorball-automation-test-\d{8}$/, 'Use an explicitly named disposable test container.');
for (const command of ['dropdb', 'createdb']) {
  const result = spawnSync('docker', ['exec', container, command, '-U', 'supabase_admin',
    ...(command === 'dropdb' ? ['--if-exists'] : []), 'mirrorball_week_automation_tests'], { encoding: 'utf8' });
  if (result.status !== 0) throw Error(result.stderr);
}
const query = (sql) => {
  const r = spawnSync('docker', ['exec', '-i', container, 'psql', '-U', 'supabase_admin', '-d',
    'mirrorball_week_automation_tests', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'], { input: "set test.owner='yes';\n" + sql, encoding: 'utf8' });
  if (r.status !== 0) throw Error(r.stderr || r.error?.message);
  return r.stdout.trim();
};
const file = async path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');
query(await file('scripts/tests/dwts-automation-fixture.sql'));
// Give the minimal fixture the real production columns used by card creation.
query(`alter table public.weeks add column is_season_finale boolean not null default false;
  create or replace function public.is_platform_admin() returns boolean language sql as $$ select current_setting('test.owner',true)='yes' $$;
  alter table public.cast_members add column role text;
  update public.cast_members set role=case when name in ('Pasha Pashkov','Rylee Arnold') then 'Pro' else 'Star' end;
  alter table public.partnerships add column active boolean not null default true;
  alter table public.dances add column name text;
`);
for (const path of ['add-dance-confirmation-tracking.sql','add-dwts-automation-functions.sql',
  'add-dwts-worker-support.sql','order-competitive-dances-by-wiki-scores.sql','add-score-desk-automation-controls.sql'])
  query(await file(`supabase/${path}`));
query(`select public.configure_dwts_automation(4,true,array['get-weeks','pre-show']);
  update public.weeks set is_complete=true where number=4;
  insert into public.weeks(number,air_date,air_start_time,air_end_time) select 5,air_date,air_start_time,air_end_time from public.weeks where number=4;
  insert into public.weeks(number) values(6);
  select public.configure_dwts_automation(5,false,array['pre-show']);
  update public.dwts_automation_weeks set wiki_tag='#Week_5:_Super_Bowl_Night' where week_id=(select id from public.weeks where number=5);
  do $$ declare s uuid;p uuid;begin for i in 1..10 loop
    insert into public.cast_members(name,role) values('Test Star '||i,'Star') returning id into s;
    insert into public.cast_members(name,role) values('Test Pro '||i,'Pro') returning id into p;
    insert into public.partnerships(star_id,pro_id) values(s,p);
  end loop;end $$;
  update public.cast_members set role='Eliminated Star',eliminated_week_id=(select id from public.weeks where number=4) where name='Test Star 10';
  update public.partnerships set active=false where star_id=(select id from public.cast_members where name='Test Star 10');
`);
const migration = await file('supabase/auto-create-week-dances-and-photo-diagnostics.sql');
query(migration);
query(migration);
assert.equal(query(`select count(*) from public.dances d join public.weeks w on w.id=d.week_id where w.number=5;`), '11');
assert.equal(query(`select count(*) from public.dances d join public.weeks w on w.id=d.week_id where w.number=6;`), '0');
assert.equal(query(`select enabled and 'pre-show'=any(modes) from public.dwts_automation_weeks a join public.weeks w on w.id=a.week_id where w.number=5;`), 't');
query(await file('scripts/tests/week-dance-creation-and-diagnostics.sql'));
console.log('Week 5 backfill, transaction-end creation, eliminated filtering, rerun safety, first-seen wiki details, two matching checks, pending-couple removal, scores/order, photo diagnostics and privileges verified.');
