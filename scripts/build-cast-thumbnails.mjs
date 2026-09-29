import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import sharp from 'sharp';

const images = new URL('../Images/', import.meta.url);
const thumbnails = new URL('../Images/Cast%20Thumbnails/', import.meta.url);
const checkOnly = process.argv.includes('--check');
if (!checkOnly) await mkdir(thumbnails, { recursive: true });
const files = (await readdir(images)).filter((name) => /\.(jpe?g|png|webp)$/i.test(name));
for (const name of files) {
  const target = new URL(`${encodeURIComponent(name.replace(/\.[^.]+$/, ''))}.webp`, thumbnails);
  const thumbnail = await sharp(await readFile(new URL(encodeURIComponent(name), images))).rotate()
    .resize(320, 320, { fit: 'inside', withoutEnlargement: true })
    .webp({ quality: 76, effort: 5 }).toBuffer();
  if (checkOnly) {
    if (!(await readFile(target)).equals(thumbnail)) throw new Error(`Cast thumbnail is out of date: ${name}`);
  } else await writeFile(target, thumbnail);
}
console.log(`${checkOnly ? 'Verified' : 'Prepared'} ${files.length} cast thumbnails.`);
