// Editorial photos supplied for the first two shows. Never substitute another
// couple's photograph when a dance has no matching image.
const weekOne = [
  'Amber Glenn and Pasha Pashkov', 'Ciara Miller and Brandon Armstrong',
  'Conner Leavitt and Adele Zaikman', 'Connor Wood and Rylee Arnold',
  'Ezra Frech and Daniella Karagach', 'Giada De Laurentiis and Alan Bersten',
  'Guillermo Rodriguez and Witney Carson', 'Harry Shum Jr. and Jenna Johnson',
  'Jackson Olson and Emma Slater', 'Jenna Dewan and Val Chmerkovskiy',
  'Julia Stiles and Ezra Sosa', 'Maura Higgins and Mark Ballas',
  'Sarah Jane Nader and Hailey Bills', 'Tatyana Ali and Jan Ravnik',
  'Taylor Hanson and Britt Stewart', 'Tyler Cameron and Sharna Burgess',
  'Troupe Showcase Dance', 'Derek Houghs Tour Performance',
];
const weekTwo = [
  'Amber Glenn and Pasha Pashkov', 'Ciara Miller and Brandon Armstrong',
  'Connor Wood and Rylee Arnold', 'Ezra Frech and Daniella Karagach',
  'Giada De Laurentiis and Alan Bersten', 'Guillermo Rodriguez and Witney Carson',
  'Harry Shum Jr. and Jenna Johnson', 'Jackson Olson and Emma Slater',
  'Jenna Dewan and Val Chmerkovskiy', 'Julia Stiles and Ezra Sosa',
  'Maura Higgins and Mark Ballas', 'Tatyana Ali and Jan Ravnik',
  'Taylor Hanson and Britt Stewart', 'Tyler Cameron and Sharna Burgess',
];
const key = (value) => String(value || '').toLowerCase().replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, ' ').trim();
const manifests = [null, new Map(weekOne.map((name) => [key(name), name])), new Map(weekTwo.map((name) => [key(name), name]))];
const treeUrl = 'https://api.github.com/repos/fkherb/mirrorball-fantasy-league/git/trees/main?recursive=1';
const rawRoot = 'https://raw.githubusercontent.com/fkherb/mirrorball-fantasy-league/main/';
const manifestUrls = [`${rawRoot}dance-photo-manifest.json`, new URL('./dance-photo-manifest.json', import.meta.url).href];
const storageKey = 'mirrorball-dance-photos-v1';
const refreshMs = 5 * 60 * 1000;
let uploadedPhotos = new Map();
let uploadedCards = new Map();
let knownEntries = [];
let lastCheck = 0;
let pendingCheck = null;
let failures = 0;

const photoKey = (week, title) => `${week}:${key(title)}`;
const photoUrl = (path, sha) => `${rawRoot}${path.split('/').map(encodeURIComponent).join('/')}?v=${encodeURIComponent(sha)}`;
const originalPattern = /^Images\/Dances\/Week (\d+)\/(.+?)-(\d+)\.(jpe?g|png|webp)$/i;
const cardPattern = /^Images\/Dances\/Card\/Week (\d+)\/(.+?)-(\d+)\.webp$/i;

// GitHub Pages cannot list a folder, so discover uploaded files from the public
// repository tree. The blob SHA also refreshes an image if an existing file is replaced.
function photoMaps(tree) {
  const groups = new Map();
  const cards = new Map();
  for (const item of tree || []) {
    if (item.type && item.type !== 'blob' || typeof item.path !== 'string' || typeof item.sha !== 'string') continue;
    const original = originalPattern.exec(item.path);
    const card = cardPattern.exec(item.path);
    const match = original || card;
    if (!match || /^elimination$/i.test(match[2])) continue;
    const groupKey = photoKey(Number(match[1]), match[2]);
    const photo = { number: Number(match[3]), path: item.path, url: photoUrl(item.path, item.sha) };
    if (card) cards.set(`${groupKey}:${photo.number}`, photo.url);
    else {
      if (!groups.has(groupKey)) groups.set(groupKey, []);
      groups.get(groupKey).push(photo);
    }
  }
  const photos = new Map();
  const cardPhotos = new Map();
  for (const [name, group] of groups) {
    group.sort((a, b) => a.number - b.number || a.path.localeCompare(b.path));
    photos.set(name, group.map((photo) => photo.url));
    cardPhotos.set(name, cards.get(`${name}:${group[0].number}`) || group[0].url);
  }
  return { photos, cardPhotos };
}

export const uploadedDancePhotos = (tree) => photoMaps(tree).photos;

function applyPhotos(entries) {
  knownEntries = entries;
  const next = photoMaps(entries);
  const changed = JSON.stringify([[...next.photos], [...next.cardPhotos]])
    !== JSON.stringify([[...uploadedPhotos], [...uploadedCards]]);
  uploadedPhotos = next.photos;
  uploadedCards = next.cardPhotos;
  if (changed && typeof window !== 'undefined') window.dispatchEvent(new Event('dance-images-updated'));
  return changed;
}

try {
  if (typeof localStorage !== 'undefined') {
    const saved = JSON.parse(localStorage.getItem(storageKey) || 'null');
    if (Array.isArray(saved?.entries)) applyPhotos(saved.entries);
  }
} catch { /* Storage can be disabled; static Week 1–2 photos still work. */ }

async function fallbackManifest(fetcher) {
  for (const url of manifestUrls) {
    try {
      const response = await fetcher(url, { cache: 'no-store' });
      if (!response.ok) continue;
      const manifest = await response.json();
      if (manifest.version === 1 && Array.isArray(manifest.entries)) return manifest.entries;
    } catch { /* Try the other copy. */ }
  }
  return null;
}

export async function refreshDanceImages({ force = false, fetcher = globalThis.fetch, now = Date.now() } = {}) {
  if (pendingCheck) return pendingCheck;
  if (!force && now - lastCheck < refreshMs * Math.min(2 ** failures, 6)) return false;
  lastCheck = now;
  pendingCheck = (async () => {
    try {
      const response = await fetcher(treeUrl, { headers: { Accept: 'application/vnd.github+json' }, cache: 'no-store' });
      if (!response.ok) throw new Error(`Photo listing returned ${response.status}`);
      const result = await response.json();
      if (result.truncated || !Array.isArray(result.tree)) throw new Error('Photo listing was incomplete');
      const changed = applyPhotos(result.tree);
      failures = 0;
      try { localStorage.setItem(storageKey, JSON.stringify({ entries: result.tree
        .filter((item) => originalPattern.test(item.path) || cardPattern.test(item.path))
        .map(({ path, sha }) => ({ path, sha })) })); } catch { /* Optional cache. */ }
      return changed;
    } catch (error) {
      failures = Math.min(failures + 1, 3);
      console.warn('Dance photo refresh failed; keeping the last available photos.', error);
      const entries = await fallbackManifest(fetcher);
      if (entries) {
        const merged = new Map(knownEntries.map((item) => [item.path, item]));
        entries.forEach((item) => merged.set(item.path, item));
        const available = [...merged.values()];
        const changed = applyPhotos(available);
        try { localStorage.setItem(storageKey, JSON.stringify({ entries: available })); } catch { /* Optional cache. */ }
        return changed;
      }
      return false;
    } finally {
      pendingCheck = null;
    }
  })();
  return pendingCheck;
}

export function startDanceImageUpdates() {
  if (typeof window === 'undefined') return;
  const check = () => { if (!document.hidden) void refreshDanceImages(); };
  check();
  window.setInterval(check, refreshMs);
  window.addEventListener('focus', check);
  document.addEventListener('visibilitychange', check);
}

export function danceImagesFor(weekNumber, title) {
  const week = Number(weekNumber);
  let normalized = key(title);
  if (week === 1 && normalized.includes('troupe') && normalized.includes('showcase')) normalized = key('Troupe Showcase Dance');
  if (week === 1 && normalized.includes('derek hough') && normalized.includes('tour')) normalized = key('Derek Houghs Tour Performance');
  const uploaded = uploadedPhotos.get(photoKey(week, normalized));
  if (uploaded) return uploaded;
  const manifest = manifests[week];
  if (!manifest) return [];
  const stem = manifest.get(normalized);
  if (!stem) return [];
  const count = stem === 'Derek Houghs Tour Performance' ? 1 : week === 2 && ['Maura Higgins and Mark Ballas', 'Tatyana Ali and Jan Ravnik'].includes(stem) ? 2 : 3;
  return Array.from({ length: count }, (_, index) => `Images/Dances/Week ${week}/${encodeURIComponent(stem)}-${index + 1}.jpeg`);
}

export function danceCardPhotoFor(weekNumber, title) {
  const week = Number(weekNumber);
  let normalized = key(title);
  if (week === 1 && normalized.includes('troupe') && normalized.includes('showcase')) normalized = key('Troupe Showcase Dance');
  if (week === 1 && normalized.includes('derek hough') && normalized.includes('tour')) normalized = key('Derek Houghs Tour Performance');
  const uploaded = uploadedCards.get(photoKey(week, normalized));
  if (uploaded) return uploaded;
  const stem = manifests[week]?.get(normalized);
  return stem ? `Images/Dances/Card/Week ${week}/${encodeURIComponent(stem)}-1.webp` : '';
}
