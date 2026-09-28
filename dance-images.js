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

export function danceImagesFor(weekNumber, title) {
  const week = Number(weekNumber);
  const manifest = manifests[week];
  if (!manifest) return [];
  let normalized = key(title);
  if (week === 1 && normalized.includes('troupe') && normalized.includes('showcase')) normalized = key('Troupe Showcase Dance');
  if (week === 1 && normalized.includes('derek hough') && normalized.includes('tour')) normalized = key('Derek Houghs Tour Performance');
  const stem = manifest.get(normalized);
  if (!stem) return [];
  const count = stem === 'Derek Houghs Tour Performance' ? 1 : week === 2 && ['Maura Higgins and Mark Ballas', 'Tatyana Ali and Jan Ravnik'].includes(stem) ? 2 : 3;
  return Array.from({ length: count }, (_, index) => `Images/Dances/Week ${week}/${encodeURIComponent(stem)}-${index + 1}.jpeg`);
}
