import assert from 'node:assert/strict';
import { standingCard, scoreRows, overviewTeamDetail, highlightCards, teamCard, teamDetail,
  castRosterRow, danceCard, teamPage, roleRatesTable, castProfile, danceDetail, judgePortraitFor, judgeMemberFor } from '../postdraft-view.js';
import { splitDanceSong, joinDanceSong } from '../dance-song.js';
import { avatarFrameFor, avatarImageStyle } from '../cast-avatar-frame.js';
import { couplePhotoFrameFor, couplePhotoStyle } from '../couple-photo-frame.js';

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
const scoredCard = danceCard({ id: 'dance-scored', kind: 'competitive', title: 'Pair',
  danceType: 'Viennese Waltz', scores: [{ judge_name: 'Carrie Ann', score: 7 },
    { judge_name: 'Guest', score: 8 }], castNames: [], scoreImage: () => '/paddle.png',
  judgePhoto: (name) => name === 'Carrie Ann' ? '/carrie.jpg' : '', photos: ['/dance.jpg'] });
assert.match(scoredCard, /Viennese Waltz/);
assert.match(scoredCard, /class="judge-score-art" role="img" aria-label="Carrie Ann: 7"/);
assert.match(scoredCard, /class="judge-score-portrait-frame"/);
assert.match(scoredCard, /class="judge-score-art judge-score-initial" role="img" aria-label="Guest: 8"/);
assert.match(scoredCard, /class="judge-score-icon" src="\/paddle\.png"/);
assert.doesNotMatch(scoredCard, /<b aria-hidden="true">7<\/b>/);
assert.match(scoredCard, /Judges total 15/);
assert.match(scoredCard, /class="dance-result-ring"/);
const couplePlaceholderCard = danceCard({ id: 'couple-photo', kind: 'competitive', title: 'Pair',
  scores: [], castNames: [], placeholderPhoto: '/couple.avif',
  placeholderStyle: 'object-position:40% 60%', poster: true });
assert.match(couplePlaceholderCard, /src="\/couple.avif"[^>]*style="object-position:40% 60%"/);
assert.doesNotMatch(couplePlaceholderCard, /dance-card-poster/);
assert.match(danceCard({ id: 'real-photo', kind: 'competitive', title: 'Pair', scores: [],
  castNames: [], photos: ['/dance.jpg'], placeholderPhoto: '/couple.avif' }), /src="\/dance.jpg"/);
assert.doesNotMatch(danceCard({ id: 'real-photo', kind: 'competitive', title: 'Pair', scores: [],
  castNames: [], photos: ['/dance.jpg'], placeholderPhoto: '/couple.avif' }), /couple.avif/);
assert.match(danceCard({ id: 'upcoming', kind: 'competitive', title: 'Pair', scores: [],
  castNames: [], weekNumber: 4, complete: false }), /prediction-ring-tba/);
assert.deepEqual(splitDanceSong('Escape (The Piña Colada Song) by Rupert Holmes'),
  { title: 'Escape (The Piña Colada Song)', artist: 'Rupert Holmes' });
assert.equal(joinDanceSong('Maneater', 'Hall & Oates'), 'Maneater by Hall & Oates');
assert.equal(joinDanceSong('Song only', ''), 'Song only');
const extraCastCard = danceCard({ id: 'dance-extra', kind: 'competitive', title: 'Pair',
  danceType: 'Foxtrot', song: 'Escape (The Piña Colada Song) by Rupert Holmes',
  scores: [{ judge_name: 'Derek', score: 7 }], castNames: ['One', 'Two'],
  scoreImage: () => '/paddle.png' });
assert.match(extraCastCard, /class="dance-song-pill"/);
assert.match(extraCastCard, /Escape \(The Piña Colada Song\)<i> by Rupert Holmes<\/i>/);
assert.match(extraCastCard, /aria-label="2 additional cast members: One, Two"/);
assert.match(extraCastCard, /class="dance-result-value"[^>]*>\+2<\/text>/);
assert.doesNotMatch(extraCastCard, /Judges total 7|class="dance-cast"/);
const performanceCard = danceCard({ id: 'opening', kind: 'performance', title: 'Opening',
  scores: [], castNames: ['One', 'Two', 'Three', 'Four'],
  castMembers: ['One', 'Two', 'Three', 'Four'].map((name) => ({ name })),
  imageFor: () => '/cast.webp' });
assert.equal((performanceCard.match(/class="dance-cast-pill"/g) || []).length, 4);
const largePerformanceCard = danceCard({ id: 'large-opening', kind: 'performance', title: 'Opening',
  scores: [], castNames: Array.from({ length: 21 }, (_, index) => `Cast ${index + 1}`),
  castMembers: Array.from({ length: 21 }, (_, index) => ({ name: `Cast ${index + 1}` })),
  imageFor: () => '/cast.webp' });
assert.equal((largePerformanceCard.match(/class="dance-cast-pill"/g) || []).length, 21);
assert.match(largePerformanceCard, /class="dance-cast-more" role="img" hidden/);
assert.doesNotMatch(largePerformanceCard, /is-avatar-grid/);
assert.match(performanceCard, /src="\/cast.webp"/);
assert.match(performanceCard, /class="cast-avatar-frame"/);
assert.deepEqual(avatarFrameFor({ profile_details: { _avatar_frame: { x: 30, y: 70, zoom: 2.2 } } }),
  { x: 30, y: 70, zoom: 2.2 });
assert.equal(avatarImageStyle({ profile_details: { _avatar_frame: { x: 30, y: 70, zoom: 2.2 } } }),
  'object-position:30% 70%;transform:scale(2.2);transform-origin:30% 70%');
assert.deepEqual(avatarFrameFor({}), { x: 50, y: 50, zoom: 1 });
assert.deepEqual(couplePhotoFrameFor({ profile_details: { _couple_photo_frames: {
  pro1: { x: 42, y: 63, zoom: 1.7 },
} } }, 'pro1'), { x: 42, y: 63, zoom: 1.7 });
assert.equal(couplePhotoStyle({ x: 42, y: 63, zoom: 1.7 }),
  'object-position:42% 63%;transform:scale(1.7);transform-origin:42% 63%');
assert.match(danceCard({ id: 'long-pair', kind: 'competitive', title: 'Guillermo Rodriguez & Witney Carson',
  shortTitle: 'Guillermo Rodriguez & Witney', scores: [], castNames: [] }),
  /data-full-title="Guillermo Rodriguez &amp; Witney Carson" data-short-title="Guillermo Rodriguez &amp; Witney"/);
assert.doesNotMatch(danceCard({ id: 'opening-photo', kind: 'performance', title: 'Opening',
  scores: [], castNames: ['One'], photos: ['/dance.jpg'] }), /dance-performance-cast/);
assert.match(danceCard({ id: 'opening-poster', kind: 'performance', title: 'Opening',
  scores: [], castNames: ['One'], poster: true }), /dance-performance-cast/);
assert.equal(judgePortraitFor('Derek Hough'), 'Images/Cast Thumbnails/Derek Hough.webp?v=2');
assert.equal(judgePortraitFor('Carrie Ann', '../'), '../Images/Cast Thumbnails/Carrie Ann Inaba.webp?v=2');
assert.equal(judgePortraitFor('Unknown Guest'), '');
assert.equal(judgeMemberFor('Carrie Ann', [{ name: 'Carrie Ann Inaba', profile_details: {} }])?.name, 'Carrie Ann Inaba');
assert.match(danceCard({ id: 'judge-frame', kind: 'competitive', title: 'Pair', scores: [{ judge_name: 'Derek', score: 7 }],
  scoreImage: () => '/paddle.png', judgePhoto: () => '/derek.webp',
  judgeMember: () => ({ name: 'Derek Hough', profile_details: { _avatar_frame: { x: 25, y: 40, zoom: 2 } } }),
  imageFor: () => '/updated-derek.webp', castNames: [] }), /src="\/updated-derek.webp" style="object-position:25% 40%;transform:scale\(2\);transform-origin:25% 40%/);
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
const availableProfile = castProfile({ member: { ...member, role: 'Star' }, image: '/portrait.png',
  role: 'Star', teamName: 'Available cast', partner: 'Partner', partnerMember: { id: 'partner-1', name: 'Partner' },
  partnerImage: '/partner.png', seasonPredictions: [{ market_kind: 'winner', percent: 12.5,
    relative_position: 0.5 }] });
assert.match(availableProfile, /class="cast-profile-control-row"><div class="cast-profile-meta"><span class="cast-profile-available">Available cast<\/span><div class="cast-mobile-pill" data-profile-control="partner"><button[^>]*class="cast-profile-avatar-button"/);
assert.match(availableProfile, /<\/div><section class="cast-market-predictions"><div class="cast-market-control cast-mobile-pill"/);
assert.match(castProfile({ member, image: '/portrait.png', role: 'Pro', backLabel: 'dance' }),
  /id="profileBack"[^>]*aria-label="Back to dance">← Back<\/button>/);
assert.match(teamDetail({ manager: 'Manager', name: 'Team', roster: [], imageFor: () => '', backLabel: 'profile' }),
  /id="teamProfileBack"[^>]*aria-label="Back to profile">← Back<\/button>/);
assert.match(danceDetail({ kind: 'competitive', title: member.name, danceType: 'Foxtrot',
  song: 'Song', scores: [{ judge_name: 'Judge', score: 8 }], scoreImage: () => '/paddle.png',
  teams: [{ name: 'Team', points: 8 }], castRows: [{ member, role: 'Pro', teamName: 'Team', points: 8 }],
  imageFor: () => '/portrait.png' }), /data-dance-cast-profile="cast-1"/);
assert.match(danceDetail({ kind: 'competitive', title: 'Pair', scores: [{ judge_name: 'Derek', score: 9 }],
  scoreImage: () => '/paddle.png', judgePhoto: () => '/derek.jpg', teams: [], castRows: [],
  imageFor: () => '' }), /aria-label="Derek: 9"/);
assert.match(danceDetail({ kind: 'competitive', title: 'Pair', scores: [], teams: [], castRows: [],
  photos: ['/photo-1.jpeg', '/photo-2.jpeg'], imageFor: () => '' }), /data-dance-gallery-photo="\/photo-2.jpeg"/);
assert.match(danceDetail({ kind: 'competitive', title: 'Pair', scores: [], teams: [], castRows: [],
  placeholderPhoto: '/couple.avif', imageFor: () => '' }), /src="\/couple.avif"/);

console.log('Shared post-draft views verified.');
