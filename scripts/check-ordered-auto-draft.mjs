import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const sql = await readFile(new URL('../supabase/ordered-auto-draft.sql', import.meta.url), 'utf8');
const ui = await readFile(new URL('../league-workspace.js', import.meta.url), 'utf8');
const startFix = await readFile(new URL('../supabase/allow-draft-start-during-airing-fix.sql', import.meta.url), 'utf8');

assert.match(sql, /drop trigger if exists guard_league_draft_start_airing_window on public\.leagues;/,
  'The pre-show rule must not block starting a draft.');
for (const source of [sql, startFix]) {
  assert.match(source, /create or replace function public\.guard_league_draft_start_airing_window\(\)[\s\S]*?begin\s+return new;\s+end;/,
    'The draft-start guard must not veto starts if an old trigger remains installed.');
}
assert.doesNotMatch(sql, /drop trigger if exists (?:guard_secondary_league_roster_change|enforce_league_draft_pick_clock)/,
  'Starting a draft must not disable the airing pause on picks.');

for (const marker of [
  'auto_draft_enabled boolean not null default false',
  "c.role = 'Pro' and v_pro < public.league_category_limit",
  "c.role = 'Star' and v_star < public.league_category_limit",
  'v_bonus < public.league_bonus_draft_limit',
  'else 3 -- Extra Pro/Star in a permitted Flex slot.',
  'public.league_pick_is_eligible(p_league_id, p_team_id, c.id)',
  'create or replace function public.set_league_auto_draft(',
  'create trigger zz_process_league_auto_draft_after_pick',
  'create trigger zz_process_league_auto_draft_after_league_change',
  'v_cast_id := public.choose_ordered_random_draft_cast(p_league_id, v_team_id);',
]) assert.ok(sql.includes(marker), `Ordered auto-draft is missing: ${marker}`);

assert.equal((sql.match(/v_cast_id := public\.choose_ordered_random_draft_cast\(p_league_id, v_team_id\);/g) || []).length, 2,
  'Both opted-in turns and timed-out turns must share the same picker.');
assert.doesNotMatch(sql, /create or replace function public\.(?:set_league_draft_deadline|advance_league_draft_deadline_after_pick|set_league_draft_paused)\(/i,
  'Auto-draft must leave the commissioner-controlled timer and pause logic unchanged.');
assert.match(sql, /and v_league\.draft_paused_at is null[\s\S]*and v_league\.draft_airing_paused_at is null/,
  'Timed-out turns must not pick during a paused or airing-locked draft.');
assert.match(ui, /db\.rpc\('set_league_auto_draft'/,
  'The draft UI must save the manager preference.');
assert.match(ui, /autoDraft: db\.from\('league_members'\)/,
  'The draft UI must load the manager preference.');
console.log('Ordered automatic draft paths verified.');
