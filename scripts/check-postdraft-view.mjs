import assert from 'node:assert/strict';
import { standingCard, scoreRows, overviewTeamDetail, highlightCards, teamCard,
  castRosterRow, danceCard, teamPage } from '../postdraft-view.js';

const member = { id: 'cast-1', name: 'A & B', image_position: 0 };
const rows = [{ member, role: 'Pro', displayRole: 'Pro', appearanceRate: 1,
  official: 30, appearances: 2, total: 32 }];

assert.match(standingCard({ id: 'team-1', rank: 1, manager: 'Manager', name: 'Team',
  contributors: [{ name: member.name, points: 32 }], total: 32, leader: true }),
  /data-standing-team="team-1"/);
assert.match(scoreRows(rows, { withImages: true, imageFor: () => '/portrait.png' }),
  /object-position:0% center/);
assert.match(scoreRows(rows), /A &amp; B/);
assert.match(overviewTeamDetail({ name: 'Team', manager: 'Manager', total: 32, castRows: rows }),
  /Selected team/);
assert.match(highlightCards({ teamScore: 32, teamNames: ['Team'], castScore: 32,
  castNames: [member.name], appearances: 2, appearanceNames: [member.name] }),
  /Team of the week/);
assert.match(teamCard({ id: 'team-1', manager: 'Manager', name: 'Team', roster: [
  { name: member.name, role: 'Pro' }], editButton: true }), /data-edit-team-id="team-1"/);
assert.match(castRosterRow({ id: member.id, name: member.name, roleDetails: 'Pro',
  image: '/portrait.png', position: 0 }), /object-position:0% center/);
assert.match(danceCard({ id: 'dance-1', kind: 'competitive', title: member.name,
  danceType: 'Foxtrot', song: 'Song', scores: [], castNames: [member.name],
  scoreImage: () => '/paddle.png', pending: true }), /Awaiting scores/);
assert.match(teamPage({ weekHistory: '<button>Week 1</button>', total: 32, period: 'season',
  rosterRows: scoreRows(rows), available: 0, availableMarkup: '' }), /team-summary-strip/);

console.log('Shared post-draft views verified.');
