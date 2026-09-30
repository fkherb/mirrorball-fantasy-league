import assert from 'node:assert/strict';
import { readdirSync, existsSync } from 'node:fs';
import { danceImagesFor, danceCardPhotoFor, couplePhotoFor, refreshDanceImages, uploadedDancePhotos } from '../dance-images.js';

for (const pair of [
  'Amber Glenn & Pasha Pashkov', 'Ciara Miller & Brandon Armstrong',
  'Conner Leavitt & Adele Zaikman', 'Connor Wood & Rylee Arnold',
  'Ezra Frech & Daniella Karagach', 'Giada De Laurentiis & Alan Bersten',
  'Guillermo Rodriguez & Witney Carson', 'Harry Shum Jr. & Jenna Johnson',
  'Jackson Olson & Emma Slater', 'Jenna Dewan & Val Chmerkovskiy',
  'Julia Stiles & Ezra Sosa', 'Maura Higgins & Mark Ballas',
  'Sarah Jane Nader & Hailey Bills', 'Tatyana Ali & Jan Ravnik',
  'Taylor Hanson & Britt Stewart', 'Tyler Cameron & Sharna Burgess',
]) {
  const photo = couplePhotoFor(pair);
  assert.ok(photo && existsSync(decodeURIComponent(photo)), `Missing couple placeholder: ${pair}`);
}

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
assert.ok(existsSync(decodeURIComponent(danceCardPhotoFor(1, 'Amber Glenn & Pasha Pashkov'))));
const tree = [
  { type: 'blob', path: 'Images/Dances/Week 3/Amber Glenn and Pasha Pashkov-2.jpg', sha: 'photo-two' },
  { type: 'blob', path: 'Images/Dances/Week 3/Amber Glenn and Pasha Pashkov-1.jpeg', sha: 'photo-one' },
  { type: 'blob', path: 'Images/Dances/Card/Week 3/Amber Glenn and Pasha Pashkov-1.webp', sha: 'card-one' },
  { type: 'blob', path: 'Images/Dances/Week 3/Elimination-1.jpeg', sha: 'editorial' },
  { type: 'blob', path: 'Images/Dances/Week 3/Other Pair-1.webp', sha: 'other' },
  { type: 'blob', path: 'Images/Dances/Week 3/notes.txt', sha: 'notes' },
];
assert.equal(uploadedDancePhotos(tree).size, 2);
const manifestFetcher = async (url) => url.includes('/git/trees/')
  ? { ok: false, status: 503 } : { ok: true, json: async () => ({ version: 1, entries: tree }) };
const originalWarn = console.warn;
try {
  console.warn = () => {}; // The simulated API outage is expected.
  assert.equal(await refreshDanceImages({ fetcher: manifestFetcher, now: 500000 }), true);
} finally {
  console.warn = originalWarn;
}
assert.match(danceCardPhotoFor(3, 'Amber Glenn & Pasha Pashkov'), /Card\/Week%203\/Amber%20Glenn%20and%20Pasha%20Pashkov-1\.webp\?v=card-one$/);
let fetchCount = 0;
const fetcher = async () => {
  fetchCount += 1;
  return { ok: true, json: async () => ({ tree, truncated: false }) };
};
assert.equal(await refreshDanceImages({ fetcher, force: true, now: 1000000 }), false);
const weekThree = danceImagesFor(3, 'Amber Glenn & Pasha Pashkov');
assert.equal(weekThree.length, 2);
assert.match(weekThree[0], /Amber%20Glenn%20and%20Pasha%20Pashkov-1\.jpeg\?v=photo-one$/);
assert.match(weekThree[1], /Amber%20Glenn%20and%20Pasha%20Pashkov-2\.jpg\?v=photo-two$/);
assert.equal(danceImagesFor(3, 'Unmatched Pair').length, 0);
assert.equal(await refreshDanceImages({ fetcher, now: 1000001 }), false);
assert.equal(fetchCount, 1);
console.log('Existing and automatically discovered dance photos verified.');
