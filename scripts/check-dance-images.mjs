import assert from 'node:assert/strict';
import { readdirSync, existsSync } from 'node:fs';
import { danceImagesFor } from '../dance-images.js';

for (const week of [1, 2]) {
  const folder = `Images/Dances/Week ${week}`;
  for (const filename of readdirSync(folder)) {
    if (filename.startsWith('Elimination-')) continue; // Editorial elimination photos, not a specific dance.
    const stem = filename.replace(/-\d+\.jpeg$/, '');
    const urls = danceImagesFor(week, stem.replace(' and ', ' & '));
    assert.ok(urls.some((url) => decodeURIComponent(url).endsWith(filename)), `Unmapped: ${filename}`);
    urls.forEach((url) => assert.ok(existsSync(decodeURIComponent(url)), `Missing: ${url}`));
  }
}
assert.equal(danceImagesFor(3, 'Amber Glenn & Pasha Pashkov').length, 0);
assert.equal(danceImagesFor(1, 'Derek Hough\'s Tour Performance').length, 1);
console.log('Week 1 and 2 dance photos verified.');
