import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { splitDanceType, joinDanceType } from '../dance-type.js';

const app = await readFile(new URL('../app.js', import.meta.url), 'utf8');
const desk = await readFile(new URL('../score-desk/index.html', import.meta.url), 'utf8');
const styles = await readFile(new URL('../score-desk.css', import.meta.url), 'utf8');
const danceTypeSql = await readFile(new URL('../supabase/standardize-dance-types.sql', import.meta.url), 'utf8');
const danceNightSql = await readFile(new URL('../supabase/add-dance-airing-night.sql', import.meta.url), 'utf8');
const completePerformanceSql = await readFile(new URL('../supabase/require-complete-performance-dances.sql', import.meta.url), 'utf8');
const atomicDanceSql = await readFile(new URL('../supabase/atomic-dance-saves-and-week-order.sql', import.meta.url), 'utf8');
assert.doesNotMatch(app, /readOnlyCards|danceCardPhotoFor/, 'Score Desk must not render the public photo cards.');
assert.match(app, /dances\.length \? dances\.map\(/, 'All weeks need the compact Score Desk dance rows.');
assert.match(app, /score-desk-judge-scores/, 'Score Desk needs readable text scores.');
assert.match(app, /judgePhoto: isScoreDeskSurface \? null : judgePhotoImage/, 'Portraits belong on the public dance page.');
assert.match(app, /prepareNextWeekCompetitiveDances\(previousWeek, week, dances\)/,
  'Opening an eligible next week should prepare its missing competitive cards.');
assert.match(app, /prepareNextWeekCompetitiveDances\(\{ \.\.\.week, is_complete: true \}, nextWeek, existingDances \|\| \[\]\)/,
  'Completing a week should prepare the next week immediately.');
assert.match(app, /<select data-judge=/, 'Judge scores must use a native selector.');
assert.match(app, /Array\.from\(\{ length: 10 \}/, 'The selector must offer scores 1 through 10.');
assert.doesNotMatch(app, /<input data-judge=/, 'Judge scores should not need typed number entry.');
assert.match(app, /db\.from\('dance_types'\)\.select\('name'\)/, 'Score Desk must load the shared dance-type catalog.');
assert.match(app, /<select id="danceType">/, 'Dance type must use a selector.');
assert.doesNotMatch(app, /<input id="danceType"/, 'Dance type must not require typed entry.');
assert.match(app, /id="danceChoreography"/, 'Performance dances need choreography editing.');
assert.match(app, /id="performanceType"/, 'Performance dances need a Type field.');
assert.match(app, /id="danceAiringNight"/, 'Both kinds of dance need a two-night airing selector.');
assert.match(app, /details\.airing_night = airingNight/, 'The selected night must be saved with each dance.');
assert.match(danceNightSql, /check \(airing_night in \(1, 2\)\)/,
  'The database must constrain airing nights to one or two.');
assert.match(app, /week\.is_complete && !scoresOnly\) return/,
  'Completed dance details must be locked while ledger score corrections remain available.');
assert.doesNotMatch(app, /Edit night|id="performanceTitle"|id="savePerformanceDetails"/,
  'Completed-week detail and night editors should be removed.');
assert.match(app, /elimination_confirmed && dance\.elimination_result/,
  'A confirmed Wiki elimination should preselect the couple at completion.');
assert.match(atomicDanceSql, /values \(p_week_id, p_kind, p_partnership_id, p_name, p_dance_type, p_song/,
  'An incomplete performance may be saved without a title or cast.');
assert.match(completePerformanceSql, /nullif\(btrim\(d\.name\), ''\) is null/,
  'Completed performances must have titles.');
assert.match(completePerformanceSql, /public\.dance_appearances a where a\.dance_id = d\.id/,
  'Completed performances must have cast.');
assert.match(completePerformanceSql, /public\.dance_judge_scores s where s\.dance_id = d\.id/,
  'Completed competitive dances must have the full judge panel scored.');
assert.match(app, /id="fusionTypeOne"/);
assert.match(app, /id="fusionTypeTwo"/);
assert.deepEqual(splitDanceType('Cha-cha/Tango Fusion'), { type: 'Fusion', first: 'Cha-cha', second: 'Tango' });
assert.equal(joinDanceType('Fusion', 'Cha-cha', 'Tango'), 'Cha-cha/Tango Fusion');
assert.equal(joinDanceType('Fusion', 'Tango', 'Tango'), null);
assert.equal(joinDanceType('Rumba'), 'Rumba');
for (const name of ['Argentine Tango', 'Rumba', 'Waltz', 'Charleston', 'Contemporary', 'Jazz', 'Hip-Hop', 'Mambo', 'Freestyle', 'Fusion'])
  assert.ok(danceTypeSql.includes(`('${name}')`), `${name} must be seeded in the catalog.`);
assert.match(danceTypeSql, /create trigger check_dance_type_catalog/, 'Database writes must validate catalog types and Fusion pairs.');
assert.match(desk, /score-desk\.css\?v=/);
assert.match(styles, /\.score-desk-page \.dance-gallery-stage \{[^}]*height: clamp\(/);
assert.match(styles, /\.score-desk-page \.dance-gallery-stage \.dance-gallery-main \{[^}]*object-fit: contain/);
console.log('Score Desk compact rows and bounded dance photos verified.');
