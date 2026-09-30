import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../app.js', import.meta.url), 'utf8');
const desk = await readFile(new URL('../score-desk/index.html', import.meta.url), 'utf8');
const styles = await readFile(new URL('../score-desk.css', import.meta.url), 'utf8');
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
assert.match(desk, /score-desk\.css\?v=/);
assert.match(styles, /\.score-desk-page \.dance-gallery-stage \{[^}]*height: clamp\(/);
assert.match(styles, /\.score-desk-page \.dance-gallery-stage \.dance-gallery-main \{[^}]*object-fit: contain/);
console.log('Score Desk compact rows and bounded dance photos verified.');
