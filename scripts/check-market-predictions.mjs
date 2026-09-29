import assert from 'node:assert/strict';
import { activePartnershipPredictionRows, seasonPredictionsFor, weeklyPredictionFor, nextPredictionWeek, isWeekAiring, predictionPercent, relativePredictionPosition } from '../market-prediction-model.js';
import { castProfile, danceCard, danceDetail } from '../postdraft-view.js';

const fresh = new Date().toISOString();
const rows = [
  { cast_member_id: 'star-1', market_kind: 'winner', percent: 30, market_status: 'active', fetched_at: fresh },
  { cast_member_id: 'star-1', market_kind: 'third', percent: 33.5, market_status: 'active', fetched_at: fresh },
  { cast_member_id: 'star-1', market_kind: 'finalist', percent: 50, market_status: 'finalized', fetched_at: fresh },
  { cast_member_id: 'star-1', market_kind: 'elimination', week_id: 'week-3', percent: 14.5, market_status: 'active', fetched_at: fresh },
  { cast_member_id: 'star-2', market_kind: 'winner', percent: 90, market_status: 'active', fetched_at: fresh },
  { cast_member_id: 'star-2', market_kind: 'elimination', week_id: 'week-3', percent: 40.5, market_status: 'active', fetched_at: fresh },
  { cast_member_id: 'star-3', market_kind: 'elimination', week_id: 'week-3', percent: 0.5, market_status: 'active', fetched_at: fresh },
];
const season = seasonPredictionsFor('star-1', rows);
assert.deepEqual(season.map((item) => item.market_kind), ['third', 'winner']);
assert.equal(predictionPercent(season[0].percent), '33.5%');
assert.equal(seasonPredictionsFor('star-1', [{ ...rows[0], fetched_at: '2020-01-01T00:00:00Z' }]).length, 0);
const weeks = [{ id: 'week-2', number: 2, is_complete: true, air_date: '2026-09-22' },
  { id: 'week-3', number: 3, is_complete: false, air_date: '2026-09-29',
    elimination_predictions_enabled: true }];
assert.equal(nextPredictionWeek(weeks, '2026-09-29').id, 'week-3');
assert.equal(nextPredictionWeek(weeks, '2026-09-30'), null);
assert.equal(nextPredictionWeek([{ ...weeks[1], second_air_date: '2026-09-30' }], '2026-09-30').id, 'week-3');
assert.equal(isWeekAiring(weeks[1], Date.parse('2026-09-30T00:00:00Z')), true);
assert.equal(isWeekAiring(weeks[1], Date.parse('2026-09-30T02:00:00Z')), false);
const weekly = weeklyPredictionFor('star-1', weeks[1], rows);
assert.equal(weekly.percent, 14.5);
assert.equal(weeklyPredictionFor('star-1', { ...weeks[1], elimination_predictions_enabled: false }, rows), null);
assert.equal(weeklyPredictionFor('star-1', weeks[1], rows, Date.parse('2026-09-30T02:00:00Z')), null);
assert.equal(relativePredictionPosition(rows[5], rows), 1);
assert.equal(relativePredictionPosition(rows[6], rows), 0);
const rankedOdds = [1, 2, 3, 40.5].map((percent, index) => ({ cast_member_id: `rank-${index}`,
  market_kind: 'elimination', week_id: 'week-3', percent, market_status: 'active', fetched_at: fresh }));
assert.equal(relativePredictionPosition(rankedOdds[1], rankedOdds), 1 / 3);
const tiedOdds = [...rankedOdds, { ...rankedOdds[1], cast_member_id: 'rank-tie' }];
assert.equal(relativePredictionPosition(tiedOdds[1], tiedOdds), 0.375);
assert.equal(relativePredictionPosition(tiedOdds[4], tiedOdds), 0.375);
const activeRows = activePartnershipPredictionRows(tiedOdds,
  tiedOdds.map((row, index) => ({ star_id: row.cast_member_id, pro_id: `pro-${index}`, active: index !== 3 })),
  tiedOdds.flatMap((row, index) => [{ id: row.cast_member_id, role: 'Star' }, { id: `pro-${index}`, role: 'Pro' }]));
assert.equal(activeRows.length, 4);
assert.equal(relativePredictionPosition(activeRows[2], activeRows), 1);
assert.equal(weeklyPredictionFor('star-1', { ...weeks[1], is_complete: true }, rows), null);

const profile = castProfile({ member: { id: 'star-1', name: 'Tatyana Ali', role: 'Star' },
  image: 'star.jpg', role: 'Star', partner: 'Pro Example', partnerMember: { id: 'pro-1', name: 'Pro Example' },
  partnerImage: 'pro.jpg', teamId: 'team-1', teamName: 'Team', teamAvatar: 'manager.jpg', fantasyPoints: 12, appearanceCount: 1,
  seasonPredictions: season, weeklyPrediction: weekly, predictionWeekNumber: 3 });
assert.match(profile, /33\.5%/);
assert.match(profile, /Season 35<\/small><strong>3rd Place/);
assert.match(profile, /14\.5%/);
assert.match(profile, /data-partner-profile="pro-1"/);
assert.match(profile, /data-cast-team-detail="team-1"/);
assert.match(profile, /manager\.jpg/);
assert.doesNotMatch(profile, /Meet dance partner/);
assert.match(profile, /Predictions provided by Kalshi/);
assert(profile.indexOf('cast-market-predictions') < profile.indexOf('cast-profile-stats'));
assert.match(profile, /prediction-ring-season/);
assert.match(profile, /prediction-ring-risk/);
assert.equal((profile.match(/class="cast-market-mini"/g) || []).length, 1);
assert.match(profile, /Week 3<\/small><strong>Elimination/);
assert.match(profile, /cast-profile-meta[\s\S]*cast-market-predictions[\s\S]*cast-profile-stats/);
assert.match(profile, /id="castSeasonPredictions" hidden/);
const fullBio = `${'A detailed biography with complete sentences. '.repeat(20)}The final sentence must remain visible.`;
const longProfile = castProfile({ member: { id: 'star-1', name: 'Tatyana Ali', role: 'Star', bio: fullBio },
  image: 'star.jpg', role: 'Star', fantasyPoints: 0 });
assert.match(longProfile, /cast-bio-preview/);
assert.match(longProfile, /The final sentence must remain visible\.<\/p><\/details>/);
assert.match(longProfile, /Show less/);
const eliminated = castProfile({ member: { id: 'star-1', name: 'Tatyana Ali', role: 'Eliminated Star' },
  image: 'star.jpg', role: 'Eliminated Star', fantasyPoints: 12,
  seasonPredictions: season, weeklyPrediction: weekly });
assert.match(eliminated, /Eliminated from the competition/);
assert.doesNotMatch(eliminated, /cast-market-predictions/);
const eliminatedPair = castProfile({ member: { id: 'pro-1', name: 'Example Pro', role: 'Eliminated Pro' },
  image: 'pro.jpg', role: 'Eliminated Pro', partner: 'Example Star',
  partnerMember: { id: 'star-1', name: 'Example Star' }, partnerImage: 'star.jpg', fantasyPoints: 0 });
assert.match(eliminatedPair, /data-partner-profile="star-1"/);

const card = danceCard({ id: 'dance-1', kind: 'competitive', title: 'Star & Pro', scores: [],
  castNames: [], scoreImage: () => '', weeklyPrediction: weekly, weekNumber: 3 });
assert.match(card, /Week 3<\/small><strong>Elimination/);
assert.match(card, /14\.5%/);
assert.match(card, /prediction-ring-risk/);
assert.doesNotMatch(card, /Predictions provided by Kalshi/);
const highestRisk = danceCard({ id: 'dance-2', kind: 'competitive', title: 'High risk', scores: [],
  castNames: [], scoreImage: () => '', photos: ['dance.jpg'], weeklyPrediction: weeklyPredictionFor('star-2', weeks[1], rows) });
assert.match(highestRisk, /--ring-color:#b63955/);
assert.match(highestRisk, /has-dance-photo/);
const detail = danceDetail({ kind: 'competitive', title: 'Star & Pro', scores: [],
  scoreImage: () => '', teams: [], castRows: [], imageFor: () => '', weeklyPrediction: weekly });
assert.match(detail, /Predictions provided by Kalshi/);
console.log('Market prediction display and filtering verified.');
