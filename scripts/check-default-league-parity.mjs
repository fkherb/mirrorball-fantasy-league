// Read-only production parity gate before routing the original league through
// the shared workspace. Run manually: node scripts/check-default-league-parity.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { calculateLeaguePoints, scoreLeague } from '../scoring.js';

const clientSource = await readFile(new URL('../supabase-client.js', import.meta.url), 'utf8');
const projectUrl = clientSource.match(/https:\/\/[a-z0-9-]+\.supabase\.co/)?.[0];
const publicKey = clientSource.match(/sb_publishable_[A-Za-z0-9_]+/)?.[0];
assert.ok(projectUrl && publicKey, 'Could not find the public Supabase connection.');
const leagueId = '00000000-0000-4000-8000-000000000001';
const accessToken = process.env.MIRRORBALL_ACCESS_TOKEN;

async function rows(table, columns, filters = {}) {
  const url = new URL(`${projectUrl}/rest/v1/${table}`);
  url.searchParams.set('select', columns);
  for (const [column, value] of Object.entries(filters)) url.searchParams.set(column, `eq.${value}`);
  const headers = { apikey: publicKey };
  if (accessToken) headers.Authorization = `Bearer ${accessToken}`;
  const response = await fetch(url, { headers });
  if (!response.ok) throw new Error(`${table}: HTTP ${response.status}`);
  return response.json();
}

const [teams, cast, pairs, weeks, dances, scores, appearances, snapshots, roles, rates, assignments] = await Promise.all([
  rows('fantasy_teams', 'id,manager_name,team_name', { league_id: leagueId }),
  rows('cast_members', 'id,role,is_hough,custom_appearance_points,eliminated_week_id,fantasy_team_id'),
  rows('partnerships', 'id,star_id,pro_id,active'),
  rows('weeks', 'id,number,is_complete'),
  rows('dances', 'id,week_id,kind,partnership_id'),
  rows('dance_judge_scores', 'dance_id,score'),
  rows('dance_appearances', 'dance_id,cast_member_id'),
  rows('weekly_roster_snapshots', 'week_id,cast_member_id,fantasy_team_id,cast_member_name,cast_role,appearance_points,manager_name,team_name,created_at', { league_id: leagueId }),
  rows('roles', 'id,name,appearance_points'),
  rows('league_role_rates', 'role_id,appearance_points', { league_id: leagueId }),
  rows('league_roster_assignments', 'cast_member_id,fantasy_team_id', { league_id: leagueId }),
]);

const completed = weeks.filter((week) => week.is_complete);
const completedIds = new Set(completed.map((week) => week.id));
const scoredDances = dances.filter((dance) => completedIds.has(dance.week_id));
const danceIds = new Set(scoredDances.map((dance) => dance.id));
const scoped = {
  teams, cast, pairs, weeks: completed, dances: scoredDances,
  scores: scores.filter((row) => danceIds.has(row.dance_id)),
  appearances: appearances.filter((row) => danceIds.has(row.dance_id)),
  snapshots, roles, rates,
};
const legacy = calculateLeaguePoints({ ...scoped, members: cast, partnerships: pairs, rosterSnapshots: snapshots });
const shared = scoreLeague(scoped, { leagueStatus: 'active', scoringStartsAfterWeek: 0 });
const snapshotByKey = new Map(snapshots.map((row) => [`${row.week_id}:${row.cast_member_id}`, row]));
const mismatches = [];
for (const week of completed) for (const team of teams) {
  const legacyTotal = [...(legacy.weekMemberPoints.get(week.id) || [])]
    .filter(([castId]) => snapshotByKey.get(`${week.id}:${castId}`)?.fantasy_team_id === team.id)
    .reduce((sum, [, points]) => sum + points.official + points.appearances, 0);
  const sharedTotal = shared.pointsByWeekTeam.get(`${week.id}:${team.id}`) || 0;
  if (legacyTotal !== sharedTotal) mismatches.push({ week: week.number, teamId: team.id, legacyTotal, sharedTotal });
}
const assignmentByCast = new Map(assignments.map((row) => [row.cast_member_id, row.fantasy_team_id]));
const assignmentMismatches = cast.filter((member) => (member.fantasy_team_id || null) !== (assignmentByCast.get(member.id) || null)).length;
const rateById = new Map(rates.map((row) => [row.role_id, row.appearance_points]));
const rateMismatches = roles.filter((role) => Number(role.appearance_points) !== Number(rateById.get(role.id))
  && !(role.appearance_points == null && rateById.get(role.id) == null)).length;
let sharedSnapshotMismatches = null;
let sharedScoreMismatches = null;
let sharedSnapshots = null;
if (accessToken) {
  const sharedRows = await rows('league_weekly_roster_snapshots',
    'week_id,cast_member_id,fantasy_team_id,cast_member_name,cast_role,appearance_points,manager_name,team_name,created_at',
    { league_id: leagueId });
  sharedSnapshots = sharedRows.length;
  const sharedByKey = new Map(sharedRows.map((row) => [`${row.week_id}:${row.cast_member_id}`, row]));
  const fields = ['fantasy_team_id', 'cast_member_name', 'cast_role', 'appearance_points', 'manager_name', 'team_name', 'created_at'];
  sharedSnapshotMismatches = snapshots.filter((row) => {
    const sharedRow = sharedByKey.get(`${row.week_id}:${row.cast_member_id}`);
    return !sharedRow || fields.some((field) => String(row[field] ?? '') !== String(sharedRow[field] ?? ''));
  }).length + sharedRows.filter((row) => !snapshotByKey.has(`${row.week_id}:${row.cast_member_id}`)).length;
  const sharedFromDatabase = scoreLeague({ ...scoped, snapshots: sharedRows },
    { leagueStatus: 'active', scoringStartsAfterWeek: 0 });
  sharedScoreMismatches = [];
  for (const week of completed) for (const team of teams) {
    const adaptedTotal = shared.pointsByWeekTeam.get(`${week.id}:${team.id}`) || 0;
    const databaseTotal = sharedFromDatabase.pointsByWeekTeam.get(`${week.id}:${team.id}`) || 0;
    if (adaptedTotal !== databaseTotal) sharedScoreMismatches.push({
      week: week.number, teamId: team.id, adaptedTotal, databaseTotal,
    });
  }
}

console.log(JSON.stringify({
  completedWeeks: completed.length, teams: teams.length, legacySnapshots: snapshots.length,
  assignmentMismatches, rateMismatches, scoreMismatches: mismatches,
  ...(accessToken ? { sharedSnapshots, sharedSnapshotMismatches, sharedScoreMismatches }
    : { sharedSnapshotVerification: 'requires an authenticated member token or the SQL cutover check' }),
}, null, 2));
if (assignmentMismatches || rateMismatches || mismatches.length || sharedSnapshotMismatches
    || sharedScoreMismatches?.length) process.exitCode = 1;
