import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const root = new URL('../', import.meta.url);
const photoRoot = new URL('../Images/Dances/', import.meta.url);
const manifestUrl = new URL('../dance-photo-manifest.json', import.meta.url);
const checkOnly = process.argv.includes('--check');
const imagePattern = /^(.+)-(\d+)\.(jpe?g|png|webp)$/i;
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex').slice(0, 16);
const relativePath = (url) => path.relative(fileURLToPath(root), fileURLToPath(url)).split(path.sep).join('/');
const entries = [];
const recordedCards = new Set();
let previousEntries = new Map();
try {
  previousEntries = new Map(JSON.parse(await readFile(manifestUrl, 'utf8')).entries
    .map((item) => [item.path, item.sha]));
} catch { /* First run has no manifest. */ }
let optimized = 0;
let originalBytes = 0;
let finalBytes = 0;

const folders = (await readdir(photoRoot, { withFileTypes: true }))
  .filter((entry) => entry.isDirectory() && /^Week \d+$/.test(entry.name))
  .map((entry) => entry.name).sort((a, b) => Number(a.slice(5)) - Number(b.slice(5)));

for (const folder of folders) {
  const sourceFolder = new URL(`${encodeURIComponent(folder)}/`, photoRoot);
  const cardFolder = new URL(`Card/${encodeURIComponent(folder)}/`, photoRoot);
  if (!checkOnly) await mkdir(cardFolder, { recursive: true });
  const files = (await readdir(sourceFolder)).filter((name) => imagePattern.test(name)).sort();
  for (const filename of files) {
    const match = imagePattern.exec(filename);
    const original = new URL(encodeURIComponent(filename), sourceFolder);
    const card = new URL(`${encodeURIComponent(match[1])}-${match[2]}.webp`, cardFolder);
    const cardPath = relativePath(card);
    const firstForCard = !recordedCards.has(cardPath);
    let sourceBytes = await readFile(original);
    originalBytes += sourceBytes.length;
    if (!checkOnly) {
      const format = match[3].toLowerCase();
      let pipeline = sharp(sourceBytes).rotate().resize(1600, 1600, { fit: 'inside', withoutEnlargement: true });
      pipeline = format === 'png' ? pipeline.png({ compressionLevel: 9 })
        : format === 'webp' ? pipeline.webp({ quality: 82, effort: 5 })
          : pipeline.jpeg({ quality: 82, mozjpeg: true });
      const smaller = await pipeline.toBuffer();
      if (smaller.length < sourceBytes.length * 0.96) {
        await writeFile(original, smaller);
        sourceBytes = smaller;
        optimized += 1;
      }
      const originalPath = relativePath(original);
      if (firstForCard) {
        let existingCard = null;
        try { existingCard = await readFile(card); } catch { /* New photo. */ }
        if (!existingCard || previousEntries.get(originalPath) !== hash(sourceBytes)
          || previousEntries.get(cardPath) !== hash(existingCard)) {
          const cardBytes = await sharp(sourceBytes).rotate()
            .resize(640, 640, { fit: 'inside', withoutEnlargement: true })
            .webp({ quality: 76, effort: 5 }).toBuffer();
          await writeFile(card, cardBytes);
        }
      }
    }
    finalBytes += sourceBytes.length;
    entries.push({ path: relativePath(original), sha: hash(sourceBytes) });
    if (firstForCard) {
      const cardBytes = await readFile(card);
      entries.push({ path: cardPath, sha: hash(cardBytes) });
      recordedCards.add(cardPath);
    }
  }
}

const manifest = `${JSON.stringify({ version: 1, entries: entries.sort((a, b) => a.path.localeCompare(b.path)) }, null, 2)}\n`;
if (checkOnly) {
  if (await readFile(manifestUrl, 'utf8') !== manifest) throw new Error('Dance photo manifest is out of date. Run npm run photos.');
  console.log(`Verified ${entries.length / 2} dance photos and card thumbnails.`);
} else {
  await writeFile(manifestUrl, manifest);
  console.log(`Prepared ${entries.length / 2} dance photos; optimized ${optimized}. ${(originalBytes / 1048576).toFixed(1)} MiB → ${(finalBytes / 1048576).toFixed(1)} MiB of originals.`);
}
