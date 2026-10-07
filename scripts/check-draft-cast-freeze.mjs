import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const sql = await readFile(new URL('../supabase/draft-start-and-frozen-cast.sql', import.meta.url), 'utf8');
const ui = await readFile(new URL('../league-workspace.js', import.meta.url), 'utf8');
const functionBody = (name) => sql.match(new RegExp(
  `create or replace function public\\.${name}\\([\\s\\S]*?\\$\\$;`, 'i'))?.[0] || '';

assert.match(sql, /draft_cast_roles jsonb not null default '\{\}'::jsonb/);
assert.match(sql, /new\.draft_cast_roles := \(select coalesce\(jsonb_object_agg\(c\.id::text, c\.role\)/);
assert.match(sql, /before update of status on public\.leagues for each row[\s\S]*capture_league_draft_cast_roles/);
assert.match(functionBody('league_draft_role'), /l\.status = 'drafting'[\s\S]*l\.draft_cast_roles/);

for (const name of [
  'league_category_limit', 'league_flex_allowance',
  'league_unreserved_active_role_count', 'league_pick_is_eligible',
  'enforce_league_draft_role_reserves', 'enforce_secondary_league_category_limit',
  'choose_ordered_random_draft_cast',
]) assert.match(functionBody(name), /public\.league_draft_role\(/,
  `${name} must use frozen roles during a draft.`);

const startGuard = functionBody('guard_league_draft_start_airing_window');
assert.match(startGuard, /old\.status = 'setup' and new\.status = 'drafting'/);
assert.match(startGuard, /where not w\.is_complete[\s\S]*clock_timestamp\(\) >= \(\(airing\.day \+ airing\.starts\)/);
assert.doesNotMatch(startGuard, /interval '15 minutes'|league_draft_airing_lock_start/,
  'The start cutoff must be actual airtime, with no pick/clock pause.');
assert.match(ui, /draftRoles: db\.rpc\('get_league_draft_cast_roles'/);
assert.match(ui, /role: assembled\.draftRoles\[member\.id\] \|\| member\.role/);
assert.match(ui, /assembled\.cast\.filter\(\(member\) => Object\.hasOwn\(assembled\.draftRoles, member\.id\)\)/,
  'Cast added after a draft starts must not enter its frozen pool.');
assert.match(ui, /readyCount === regularMembers\.length && enoughEligibleCast && !context\.draftStartBlocked/);
console.log('Draft start cutoff and frozen cast roles verified.');
