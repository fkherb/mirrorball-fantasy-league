import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { photoRepositoryFor, photoRepositoryEndpoints } from '../repository-location.js';

for (const path of ['/mirrorball-fantasy/', '/mirrorball-fantasy/score-desk/index.html',
  '/mirrorball-fantasy/cast-roster/', '/mirrorball-fantasy']) {
  const endpoints = photoRepositoryEndpoints(`https://fkherb.github.io${path}?join=ABC#dances`);
  assert.equal(endpoints.repository, 'fkherb/mirrorball-fantasy');
  assert.match(endpoints.treeUrl, /\/repos\/fkherb\/mirrorball-fantasy\/git\/trees\/main/);
  assert.equal(endpoints.rawRoot, 'https://raw.githubusercontent.com/fkherb/mirrorball-fantasy/main/');
}
for (const url of ['https://fkherb.github.io/mirrorball-fantasy-league/dance-images.js',
  'http://localhost:3000/dance-images.js', 'file:///preview/dance-images.js',
  'https://fkherb.github.io/mirrorball-fantasy-other/?repo=evil/repo']) {
  assert.equal(photoRepositoryFor(url), 'fkherb/mirrorball-fantasy-league');
}

const root = new URL('../migration/github-user-site/', import.meta.url);
const aasa = JSON.parse(await readFile(new URL('.well-known/apple-app-site-association', root), 'utf8'));
const detail = aasa.applinks.details[0];
assert.deepEqual(detail.appIDs, ['5TXGRKPUC4.com.mirrorball-fantasy']);
assert.deepEqual(detail.components.map(c => c['/']), ['/mirrorball-fantasy-league/*', '/mirrorball-fantasy/*']);
assert.ok(detail.components.every(c => c['?'].join === '?*'));
await readFile(new URL('.nojekyll', root));
const script = await readFile(new URL('repo-redirect.js', root), 'utf8');
const redirected = href => {
  const results = [];
  const link = {};
  runInNewContext(script, { URL, location: { href, replace: value => results.push(value) },
    document: { querySelector: () => link } });
  if (results.length) assert.equal(link.href, results[0]);
  return results;
};
assert.deepEqual(redirected('https://fkherb.github.io/mirrorball-fantasy-league/?join=AbC%2B123&league=x#standings'),
  ['https://fkherb.github.io/mirrorball-fantasy/?join=AbC%2B123&league=x#standings']);
assert.deepEqual(redirected('https://fkherb.github.io/mirrorball-fantasy-league/privacy/?lang=en#contact'),
  ['https://fkherb.github.io/mirrorball-fantasy/privacy/?lang=en#contact']);
assert.deepEqual(redirected('https://fkherb.github.io/mirrorball-fantasy-league/#access_token=fixture&refresh_token=fixture'),
  ['https://fkherb.github.io/mirrorball-fantasy/#access_token=fixture&refresh_token=fixture']);
assert.deepEqual(redirected('https://fkherb.github.io/mirrorball-fantasy-league'),
  ['https://fkherb.github.io/mirrorball-fantasy/']);
assert.deepEqual(redirected('https://fkherb.github.io/mirrorball-fantasy/'), []);
assert.deepEqual(redirected('https://fkherb.github.io/other-project/?join=123'), []);
assert.deepEqual(redirected('https://example.com/mirrorball-fantasy-league/'), []);
for (const path of ['404.html', 'mirrorball-fantasy-league/index.html',
  'mirrorball-fantasy-league/privacy/index.html', 'mirrorball-fantasy-league/beta/index.html']) {
  const html = await readFile(new URL(path, root), 'utf8');
  assert.match(html, /<script src="\/repo-redirect\.js"><\/script>/);
  assert.match(html, /name="referrer" content="no-referrer"/);
}
console.log('Repository photo routing, both app-link paths, and safe legacy redirects verified.');
