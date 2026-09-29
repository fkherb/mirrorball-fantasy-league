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
const refreshMs = 5 * 60 * 1000;
let uploadedPhotos = new Map();
let lastCheck = 0;
let pendingCheck = null;

const photoKey = (week, title) => `${week}:${key(title)}`;
const photoUrl = (path, sha) => `${rawRoot}${path.split('/').map(encodeURIComponent).join('/')}?v=${encodeURIComponent(sha)}`;

// GitHub Pages cannot list a folder, so discover uploaded files from the public
// repository tree. The blob SHA also refreshes an image if an existing file is replaced.
export function uploadedDancePhotos(tree) {
  const groups = new Map();
  for (const item of tree || []) {
    if (item.type !== 'blob' || typeof item.path !== 'string' || typeof item.sha !== 'string') continue;
    const match = /^Images\/Dances\/Week (\d+)\/(.+?)-(\d+)\.(jpe?g|png|webp)$/i.exec(item.path);
    if (!match || /^elimination$/i.test(match[2])) continue;
    const groupKey = photoKey(Number(match[1]), match[2]);
    if (!groups.has(groupKey)) groups.set(groupKey, []);
    groups.get(groupKey).push({ number: Number(match[3]), path: item.path, url: photoUrl(item.path, item.sha) });
  }
  return new Map([...groups].map(([name, photos]) => [name, photos
    .sort((a, b) => a.number - b.number || a.path.localeCompare(b.path))
    .map((photo) => photo.url)]));
}

export async function refreshDanceImages({ force = false, fetcher = globalThis.fetch, now = Date.now() } = {}) {
  if (pendingCheck) return pendingCheck;
  if (!force && now - lastCheck < refreshMs) return false;
  lastCheck = now;
  pendingCheck = (async () => {
    try {
      const response = await fetcher(treeUrl, { headers: { Accept: 'application/vnd.github+json' }, cache: 'no-store' });
      if (!response.ok) throw new Error(`Photo listing returned ${response.status}`);
      const result = await response.json();
      if (result.truncated || !Array.isArray(result.tree)) throw new Error('Photo listing was incomplete');
      const next = uploadedDancePhotos(result.tree);
      const changed = JSON.stringify([...next]) !== JSON.stringify([...uploadedPhotos]);
      uploadedPhotos = next;
      if (changed && typeof window !== 'undefined') window.dispatchEvent(new Event('dance-images-updated'));
      return changed;
    } catch (error) {
      console.warn('Dance photo refresh failed; keeping the last available photos.', error);
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
