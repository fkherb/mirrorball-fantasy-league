import assert from 'node:assert/strict';
import { standingCard, scoreRows, overviewTeamDetail, highlightCards, teamCard, teamDetail,
  castRosterRow, danceCard, teamPage, roleRatesTable, castProfile, danceDetail } from '../postdraft-view.js';

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
assert.match(teamDetail({ manager: 'Manager', name: 'Team', roster: [{ ...member, role: 'Pro' }],
  imageFor: () => '/portrait.png' }), /data-team-cast-detail="cast-1"/);
assert.match(castRosterRow({ id: member.id, name: member.name, roleDetails: 'Pro',
  image: '/portrait.png', position: 0 }), /object-position:0% center/);
assert.match(danceCard({ id: 'dance-1', kind: 'competitive', title: member.name,
  danceType: 'Foxtrot', song: 'Song', scores: [], castNames: [member.name],
  scoreImage: () => '/paddle.png', pending: true }), /Awaiting scores/);
assert.match(danceCard({ id: 'dance-photo', kind: 'competitive', title: 'Pair',
  danceType: 'Foxtrot', song: 'Song', scores: [], castNames: [], scoreImage: () => '/paddle.png',
  photos: ['Images/Dances/Week%201/Pair-1.jpeg'] }), /dance-card-photo/);
assert.match(danceCard({ id: 'dance-poster', kind: 'performance', title: 'Opening',
  scores: [], castNames: [], poster: true }), /dance-card-poster/);
assert.match(teamPage({ weekHistory: '<button>Week 1</button>', total: 32, period: 'season',
  rosterRows: scoreRows(rows), available: 0, availableMarkup: '' }), /team-summary-strip/);
assert.match(roleRatesTable([{ name: 'Surprise', appearance_points: null },
  { name: 'Star', appearance_points: 2 }]), /Surprise \*/);
assert.match(castProfile({ member, image: '/portrait.png', role: 'Pro', teamName: 'Team',
  fantasyPoints: 32, judgesTotal: 30, appearanceCount: 2, showJudges: true }),
  /cast-profile-stats/);
assert.match(castProfile({ member: { ...member, role: 'Star' }, image: '/portrait.png', role: 'Star',
  teamName: 'Team', seasonPredictions: [{ market_kind: 'winner', percent: 12.5,
    relative_position: 0.5 }] }), /Season 35<\/small><strong>Winner<\/strong>/);
assert.match(danceDetail({ kind: 'competitive', title: member.name, danceType: 'Foxtrot',
  song: 'Song', scores: [{ judge_name: 'Judge', score: 8 }], scoreImage: () => '/paddle.png',
  teams: [{ name: 'Team', points: 8 }], castRows: [{ member, role: 'Pro', teamName: 'Team', points: 8 }],
  imageFor: () => '/portrait.png' }), /data-dance-cast-profile="cast-1"/);
assert.match(danceDetail({ kind: 'competitive', title: 'Pair', scores: [], teams: [], castRows: [],
  photos: ['/photo-1.jpeg', '/photo-2.jpeg'], imageFor: () => '' }), /data-dance-gallery-photo="\/photo-2.jpeg"/);

console.log('Shared post-draft views verified.');
