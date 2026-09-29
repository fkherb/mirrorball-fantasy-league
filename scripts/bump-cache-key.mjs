import { readFile, writeFile } from 'node:fs/promises';

const [oldKey, newKey] = process.argv.slice(2);
if (!oldKey || !newKey || oldKey === newKey || !/^[\w-]+$/.test(newKey)) {
  throw new Error('Usage: node scripts/bump-cache-key.mjs <old-key> <new-key>');
}

const files = [
  'index.html', 'score-desk/index.html', 'cast-roster/index.html',
  'app.js', 'ui.js', 'league-workspace.js', 'market-predictions.js',
  'week-airing-policy.js', 'score-desk/score-desk-ui.js',
  'cast-roster/cast-roster-ui.js',
];

for (const file of files) {
  const path = new URL(`../${file}`, import.meta.url);
  const original = await readFile(path, 'utf8');
  if (!original.includes(oldKey)) throw new Error(`${file} does not contain ${oldKey}`);
  await writeFile(path, original.replaceAll(oldKey, newKey));
}

console.log(`Updated cache key in ${files.length} files: ${newKey}`);
