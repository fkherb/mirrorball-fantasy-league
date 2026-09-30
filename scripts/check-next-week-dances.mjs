import assert from 'node:assert/strict';
import { nextWeekCompetitiveDanceRows } from '../next-week-dance-plan.js';

const completed = { id: 'week-3', number: 3, is_complete: true };
const next = { id: 'week-4', number: 4, is_complete: false };
const cast = [
  { id: 'star-a', name: 'Amber', role: 'Star' }, { id: 'pro-a', role: 'Pro' },
  { id: 'star-b', name: 'Ciara', role: 'Star' }, { id: 'pro-b', role: 'Pro' },
  { id: 'star-out', name: 'Taylor', role: 'Eliminated Star', eliminated_week_id: 'week-3' },
  { id: 'pro-out', role: 'Eliminated Pro', eliminated_week_id: 'week-3' },
  { id: 'star-stale', name: 'Stale', role: 'Star', eliminated_week_id: 'week-3' },
  { id: 'pro-stale', role: 'Pro' },
];
const partnerships = [
  { id: 'pair-b', star_id: 'star-b', pro_id: 'pro-b', active: true },
  { id: 'pair-out', star_id: 'star-out', pro_id: 'pro-out', active: false },
  { id: 'pair-a', star_id: 'star-a', pro_id: 'pro-a', active: true },
  { id: 'pair-stale', star_id: 'star-stale', pro_id: 'pro-stale', active: true },
];
const plan = (previous, upcoming, existing = []) => nextWeekCompetitiveDanceRows(
  previous, upcoming, partnerships, cast, existing);

assert.deepEqual(plan(completed, next).map((row) => [row.partnership_id, row.sort_order]),
  [['pair-a', 1], ['pair-b', 2]]);
assert.deepEqual(plan(completed, next, [
  { kind: 'competitive', partnership_id: 'pair-a', sort_order: 4 },
  { kind: 'performance', partnership_id: null, sort_order: 5 },
]).map((row) => [row.partnership_id, row.sort_order]), [['pair-b', 6]]);
assert.deepEqual(plan(completed, next, [
  { kind: 'competitive', partnership_id: 'pair-a', sort_order: 1 },
  { kind: 'competitive', partnership_id: 'pair-b', sort_order: 2 },
]), []);
assert.deepEqual(plan({ ...completed, is_complete: false }, next), []);
assert.deepEqual(plan({ ...completed, is_season_finale: true }, next), []);
assert.deepEqual(plan(completed, { ...next, number: 5 }), []);
assert.deepEqual(plan(completed, { ...next, is_complete: true }), []);

console.log('Next-week competitive dance preparation verified.');
