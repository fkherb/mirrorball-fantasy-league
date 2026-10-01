// Fusion uses two catalog styles but stays compatible with the existing
// dances.dance_type text field and public dance-card labels.
export function splitDanceType(value) {
  const label = String(value || '').trim();
  const fusion = label.match(/^([^/]+)\/([^/]+) Fusion$/);
  return fusion
    ? { type: 'Fusion', first: fusion[1].trim(), second: fusion[2].trim() }
    : { type: label, first: '', second: '' };
}

export function joinDanceType(type, first = '', second = '') {
  const selected = String(type || '').trim();
  if (!selected) return null;
  if (selected !== 'Fusion') return selected;
  const a = String(first || '').trim();
  const b = String(second || '').trim();
  return a && b && a !== b ? `${a}/${b} Fusion` : null;
}
