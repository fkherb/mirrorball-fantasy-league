import { readFile } from 'node:fs/promises';

const entrypoints = ['index.html', 'score-desk/index.html', 'cast-roster/index.html'];
const versions = new Map();

for (const file of entrypoints) {
  const html = await readFile(new URL(`../${file}`, import.meta.url), 'utf8');
  const matches = [...html.matchAll(/(?:app|ui|score-desk-ui|cast-roster-ui|styles|roster)\.js?|(?:styles|roster)\.css/g)];
  const keys = [...html.matchAll(/(?:src|href)="[^"]+\.(?:js|css)\?v=([^"]+)"/g)].map((match) => match[1]);
  if (!matches.length || !keys.length) throw new Error(`${file} is missing versioned static assets.`);
  for (const key of keys) versions.set(key, [...(versions.get(key) || []), file]);
}

if (versions.size !== 1) {
  const detail = [...versions].map(([key, files]) => `${key}: ${[...new Set(files)].join(', ')}`).join('\n');
  throw new Error(`Static asset cache keys do not match:\n${detail}`);
}

const expectedKey = [...versions.keys()][0];
for (const file of ['app.js', 'ui.js', 'league-workspace.js', 'score-desk/score-desk-ui.js', 'cast-roster/cast-roster-ui.js']) {
  const module = await readFile(new URL(`../${file}`, import.meta.url), 'utf8');
  const moduleKeys = [...module.matchAll(/from ['"][^'"]+\.js\?v=([^'"]+)['"]/g)].map((match) => match[1]);
  if (!moduleKeys.length || moduleKeys.some((key) => key !== expectedKey)) {
    throw new Error(`${file} module import cache key must match ${expectedKey}.`);
  }
}

console.log(`Static asset cache key verified: ${expectedKey}`);
