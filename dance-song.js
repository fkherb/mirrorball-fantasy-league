// Songs are still stored as one value so existing dances and database writes
// remain compatible. Editors and cards can treat the two parts separately.
export function splitDanceSong(value) {
  const song = String(value || '').trim();
  const separator = song.lastIndexOf(' by ');
  return separator > 0
    ? { title: song.slice(0, separator).trim(), artist: song.slice(separator + 4).trim() }
    : { title: song, artist: '' };
}

export function joinDanceSong(title, artist) {
  const cleanTitle = String(title || '').trim();
  const cleanArtist = String(artist || '').trim();
  return cleanTitle ? `${cleanTitle}${cleanArtist ? ` by ${cleanArtist}` : ''}` : '';
}
