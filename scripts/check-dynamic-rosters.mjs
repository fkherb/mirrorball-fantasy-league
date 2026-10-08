import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { calculateRosterLimits, rosterExchangeIssue, draftCanFinish, draftCategoryEligibility } from '../roster-rules.js';

let scenarios = 0;
for (const [teams, size] of [[3,12],[4,10],[5,8]]) for (let couples=16;couples>=4;couples--) {
  const limits=calculateRosterLimits(couples,couples,teams,size);
  assert.equal(limits.active_max,Math.ceil(2*couples/teams));
  assert.equal(limits.pro_max,Math.ceil(couples/teams));
  assert.equal(limits.bonus_max,size-limits.active_max+1);
  const counts=Array.from({length:teams},()=>({Pro:0,Star:0,Bonus:0}));
  const pool={Pro:couples,Star:couples,Bonus:44-2*couples};
  assert.ok(draftCanFinish(pool,counts,limits));
  for(let round=0;round<size;round++) for(let position=0;position<teams;position++) {
    const team=round%2 ? teams-position-1 : position;
    const eligible=draftCategoryEligibility(pool,counts,team,limits);
    const role=['Pro','Star','Bonus'].find(role=>eligible[role]);
    assert.ok(role,`Stranded draft: ${teams} teams / ${couples} couples.`);
    counts[team][role]++; pool[role]--;
    assert.ok(draftCanFinish(pool,counts,limits));
  }
  counts.forEach(c=>assert.equal(c.Pro+c.Star+c.Bonus,size));
  scenarios++;
}
const limits=calculateRosterLimits(11,11,4,10);
assert.deepEqual([limits.active_max,limits.pro_max,limits.bonus_max],[6,3,5]);
assert.equal(rosterExchangeIssue({Pro:2,Star:3,Bonus:5},limits,'Bonus','Pro'),'');
assert.equal(rosterExchangeIssue({Pro:3,Star:3,Bonus:4},limits,'Pro','Bonus'),'');
assert.match(rosterExchangeIssue({Pro:3,Star:3,Bonus:4},limits,'Bonus','Star'),/Star limit/);
assert.equal(rosterExchangeIssue({Pro:2,Star:2,Bonus:6},limits,'Bonus','Pro'),'');
assert.match(rosterExchangeIssue({Pro:2,Star:2,Bonus:6},limits,'Star','Pro'),/over-limit category/);
assert.match(rosterExchangeIssue({Pro:2,Star:2,Bonus:6},limits,'Bonus','Bonus'),/reduce an excess/);
const reduced=calculateRosterLimits(6,6,4,10);
assert.equal(rosterExchangeIssue({Pro:3,Star:1,Bonus:6},reduced,'Pro','Bonus'),'');
assert.match(rosterExchangeIssue({Pro:3,Star:1,Bonus:6},reduced,'Star','Bonus'),/over-limit category/);
assert.match(rosterExchangeIssue({Pro:3,Star:1,Bonus:6},reduced,'Pro','Star'),/reduce an excess|combined/);
assert.equal(rosterExchangeIssue({Pro:4,Star:1,Bonus:5},reduced,'Pro','Bonus'),'','Partial corrections must work.');
assert.equal(rosterExchangeIssue({Pro:2,Star:3,Bonus:5},{...reduced,exempt:true},'Bonus','Star'),'');
const late=calculateRosterLimits(4,4,5,8);
assert.deepEqual([late.active_max,late.pro_max,late.bonus_max],[2,1,7]);
assert.equal(rosterExchangeIssue({Pro:0,Star:0,Bonus:8},late,'Bonus','Star'),'');
const teams=[{Pro:3,Star:3,Bonus:0},{Pro:3,Star:3,Bonus:0},{Pro:3,Star:2,Bonus:0},{Pro:0,Star:0,Bonus:0}];
assert.equal(draftCategoryEligibility({Pro:2,Star:3,Bonus:22},teams,2,limits).Star,false);
const sql=await readFile(new URL('../supabase/dynamic-roster-limits.sql',import.meta.url),'utf8');
assert.match(sql,/referencing old table as old_rosters new table as new_rosters/i);
assert.match(sql,/v_edges\[v_a\]\[v_t\]/);
assert.match(sql,/p_league_id=public.default_fantasy_league_id\(\)/);
const ui=await readFile(new URL('../league-workspace.js',import.meta.url),'utf8');
assert.doesNotMatch(ui,/Flex \(Pro or Star\)|then Flex|draftFlexAllowance/);
assert.match(ui,/get_league_roster_rules/);
assert.match(ui,/releaseOptions\.map/);
console.log(`${scenarios} complete snake drafts, dynamic caps, supply protection, exemption and corrective exchanges verified.`);
