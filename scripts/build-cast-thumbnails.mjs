import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import sharp from 'sharp';

const images = new URL('../Images/', import.meta.url);
const thumbnails = new URL('../Images/Cast%20Thumbnails/', import.meta.url);
const manifestUrl = new URL('../cast-thumbnail-manifest.json', import.meta.url);
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex').slice(0, 16);
const checkOnly = process.argv.includes('--check');
if (!checkOnly) await mkdir(thumbnails, { recursive: true });
let previous = null;
try { previous = JSON.parse(await readFile(manifestUrl, 'utf8')); } catch { /* First run. */ }
const previousEntries = new Map((previous?.entries || []).map((entry) => [entry.source, entry]));
const files = (await readdir(images)).filter((name) => /\.(jpe?g|png|webp)$/i.test(name)).sort();
const entries = [];
for (const name of files) {
  const source = `Images/${name}`;
  const sourceBytes = await readFile(new URL(encodeURIComponent(name), images));
  const sourceSha = hash(sourceBytes);
  const target = new URL(`${encodeURIComponent(name.replace(/\.[^.]+$/, ''))}.webp`, thumbnails);
  const thumbnail = `Images/Cast Thumbnails/${name.replace(/\.[^.]+$/, '')}.webp`;
  let thumbnailBytes = null;
  try { thumbnailBytes = await readFile(target); } catch { /* New portrait. */ }
  const old = previousEntries.get(source);
  if (!checkOnly && (!thumbnailBytes || previous && (!old || old.sourceSha !== sourceSha
      || old.thumbnailSha !== hash(thumbnailBytes)))) {
    thumbnailBytes = await sharp(sourceBytes).rotate()
      .resize(320, 320, { fit: 'inside', withoutEnlargement: true })
      .webp({ quality: 76, effort: 5 }).toBuffer();
    await writeFile(target, thumbnailBytes);
  }
  if (!thumbnailBytes) throw new Error(`Missing cast thumbnail: ${name}`);
  entries.push({ source, sourceSha, thumbnail, thumbnailSha: hash(thumbnailBytes) });
}
const manifest = `${JSON.stringify({ version: 1, entries }, null, 2)}\n`;
if (checkOnly) {
  if (await readFile(manifestUrl, 'utf8') !== manifest) throw new Error('Cast thumbnail manifest is out of date. Run npm run photos.');
} else await writeFile(manifestUrl, manifest);
console.log(`${checkOnly ? 'Verified' : 'Prepared'} ${files.length} cast thumbnails.`);
