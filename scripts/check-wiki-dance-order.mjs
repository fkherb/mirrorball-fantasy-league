import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/order-competitive-dances-by-wiki-scores.sql', import.meta.url), 'utf8');
const wiki = await readFile(new URL('./Automations/dwts-wiki.py', import.meta.url), 'utf8');
const desk = await readFile(new URL('../app.js', import.meta.url), 'utf8');
const publicPage = await readFile(new URL('../league-workspace.js', import.meta.url), 'utf8');

assert.match(wiki, /data\["table_index"\] = table_index/);
assert.match(wiki, /data\["row_index"\] = row_index/);
assert.match(migration, /report_dwts_work_base\(p_worker,p_run,p_result\)/);
assert.match(migration, /wiki_score_sequence nulls last/);
assert.match(migration, /order by table_index,row_index,star_name,d\.id/);
assert.match(migration, /d\.kind = 'competitive'/);
assert.match(migration, /dance_order_manually_set/);
assert.match(migration, /current_setting\('mirrorball\.automation_import',true\) is distinct from 'on'/);
assert.match(desk, /db\.from\('dances'\)\.select\('\*'\)\.eq\('week_id', week\.id\)\.order\('sort_order'\)/);
assert.match(publicPage, /dances: db\.from\('dances'\)\.select\('\*'\)\.order\('sort_order'\)/);
console.log('Wiki score-arrival dance ordering verified.');
