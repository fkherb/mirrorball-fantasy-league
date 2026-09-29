import assert from 'node:assert/strict';
import { appearanceValue, calculateLeaguePoints, roleForWeek, scoreLeague } from '../scoring.js';

const roleWeeks = [{ id: 'exit-week', number: 2 }, { id: 'later-week', number: 3 }];
const eliminatedStar = { role: 'Eliminated Star', eliminated_week_id: 'exit-week' };
assert.equal(roleForWeek(eliminatedStar, roleWeeks[0], roleWeeks), 'Star');
assert.equal(roleForWeek(eliminatedStar, roleWeeks[1], roleWeeks), 'Eliminated Star');
assert.equal(appearanceValue({ role: 'Pro', is_hough: true }, new Map([['Hough', { appearance_points: 7 }]]), roleWeeks[0], roleWeeks), 7);

const fixture = {
  teams: [{ id: 'team-a' }, { id: 'team-b' }],
  cast: [
    { id: 'star', role: 'Eliminated Star' },
    { id: 'pro', role: 'Eliminated Pro' },
    { id: 'bonus', role: 'Troupe' },
  ],
  pairs: [{ id: 'pair', star_id: 'star', pro_id: 'pro', active: false }],
  weeks: [{ id: 'week-1', number: 1, is_complete: true }, { id: 'week-2', number: 2, is_complete: true }],
  dances: [
    { id: 'dance-1', week_id: 'week-1', kind: 'competitive', partnership_id: 'pair' },
    { id: 'dance-2', week_id: 'week-2', kind: 'competitive', partnership_id: 'pair' },
  ],
  scores: [
    { dance_id: 'dance-1', score: 7 }, { dance_id: 'dance-1', score: 8 },
    { dance_id: 'dance-1', score: 9 }, { dance_id: 'dance-1', score: 10 },
    { dance_id: 'dance-2', score: 6 }, { dance_id: 'dance-2', score: 7 },
  ],
  appearances: [
    { dance_id: 'dance-1', cast_member_id: 'bonus' },
    { dance_id: 'dance-2', cast_member_id: 'bonus' },
  ],
  roles: [{ id: 'troupe-rate', name: 'Troupe', appearance_points: 99 }],
  rates: [{ role_id: 'troupe-rate', appearance_points: 10 }],
  snapshots: [
    { week_id: 'week-1', cast_member_id: 'star', fantasy_team_id: 'team-a', cast_role: 'Star' },
    { week_id: 'week-1', cast_member_id: 'pro', fantasy_team_id: 'team-a', cast_role: 'Pro' },
    { week_id: 'week-1', cast_member_id: 'bonus', fantasy_team_id: 'team-b', cast_role: 'Troupe', appearance_points: 2 },
    { week_id: 'week-2', cast_member_id: 'star', fantasy_team_id: 'team-a', cast_role: 'Eliminated Star' },
    { week_id: 'week-2', cast_member_id: 'pro', fantasy_team_id: 'team-a', cast_role: 'Eliminated Pro' },
    { week_id: 'week-2', cast_member_id: 'bonus', fantasy_team_id: 'team-b', cast_role: 'Troupe', appearance_points: 5 },
  ],
};

const active = { leagueStatus: 'active', scoringStartsAfterWeek: 0 };
const scored = scoreLeague(fixture, active);
assert.equal(scored.totalByTeam.get('team-a'), 94, 'an inactive partnership still scores historical dances and guest-judge scores');
assert.equal(scored.totalByTeam.get('team-b'), 7, 'frozen weekly rates override current rates');
assert.equal(scored.pointsByWeekTeam.get('week-1:team-a'), 68);
assert.equal(scored.pointsByWeekTeam.get('week-2:team-a'), 26);
assert.deepEqual(scored.pointsByWeekCast.get('week-2:bonus'), { official: 0, appearances: 5 });

const lateStart = scoreLeague(fixture, { ...active, scoringStartsAfterWeek: 1 });
assert.equal(lateStart.totalByTeam.get('team-a'), 26);
assert.equal(lateStart.totalByTeam.get('team-b'), 5);
assert.equal(scoreLeague(fixture, { ...active, leagueStatus: 'drafting' }).totalByTeam.get('team-a'), 0);
assert.throws(() => scoreLeague({ ...fixture, snapshots: fixture.snapshots.filter((row) => row.week_id !== 'week-2') }, active), /missing this league’s roster snapshot/);
assert.throws(() => scoreLeague({ ...fixture, snapshots: fixture.snapshots.filter((row) => !(row.week_id === 'week-2' && row.cast_member_id === 'pro')) }, active), /missing a cast roster snapshot/);

// The two live paths must agree before the default league is routed through
// the shared workspace. This fixture uses rates identical across both weeks.
const parityFixture = {
  ...fixture,
  roles: [{ id: 'troupe-rate', name: 'Troupe', appearance_points: 2 }],
  rates: [{ role_id: 'troupe-rate', appearance_points: 2 }],
  snapshots: fixture.snapshots.map((snapshot) => ({ ...snapshot, appearance_points: snapshot.cast_member_id === 'bonus' ? 2 : null })),
};
const original = calculateLeaguePoints({
  teams: parityFixture.teams,
  members: parityFixture.cast,
  roles: parityFixture.roles,
  partnerships: parityFixture.pairs,
  weeks: parityFixture.weeks,
  dances: parityFixture.dances,
  scores: parityFixture.scores,
  appearances: parityFixture.appearances,
  rosterSnapshots: parityFixture.snapshots,
});
const shared = scoreLeague(parityFixture, active);
for (const week of parityFixture.weeks) {
  for (const team of parityFixture.teams) {
    const originalTotal = [...(original.weekMemberPoints.get(week.id) || [])]
      .filter(([castId]) => parityFixture.snapshots.find((row) => row.week_id === week.id && row.cast_member_id === castId)?.fantasy_team_id === team.id)
      .reduce((sum, [, points]) => sum + points.official + points.appearances, 0);
    assert.equal(shared.pointsByWeekTeam.get(`${week.id}:${team.id}`) || 0, originalTotal);
  }
}

console.log('League scoring fixtures verified.');
