import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { splitDanceType, joinDanceType } from '../dance-type.js';

const app = await readFile(new URL('../app.js', import.meta.url), 'utf8');
const desk = await readFile(new URL('../score-desk/index.html', import.meta.url), 'utf8');
const styles = await readFile(new URL('../score-desk.css', import.meta.url), 'utf8');
const danceTypeSql = await readFile(new URL('../supabase/standardize-dance-types.sql', import.meta.url), 'utf8');
const danceNightSql = await readFile(new URL('../supabase/add-dance-airing-night.sql', import.meta.url), 'utf8');
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
assert.match(app, /id="performanceTitle"/, 'Completed performance titles should remain editable for backfill.');
assert.match(app, /id="danceAiringNight"/, 'Both kinds of dance need a two-night airing selector.');
assert.match(app, /week\.is_complete && week\.second_air_date && dance\.kind === 'competitive'/,
  'Completed competitive dances need a night-only editor.');
assert.match(app, /airing_night: night/, 'The selected night must be saved with each dance.');
assert.match(danceNightSql, /check \(airing_night in \(1, 2\)\)/,
  'The database must constrain airing nights to one or two.');
assert.match(app, /week\.is_complete && dance\.kind === 'performance'/,
  'Completed performances need a details-only editor.');
assert.match(app, /\.eq\('week_id', week\.id\)\.eq\('kind', 'performance'\)\.select\('id'\)/,
  'Completed performance metadata should save without changing historical scoring.');
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
