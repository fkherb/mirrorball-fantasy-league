// Plan blank competitive cards only for the week immediately after a completed
// episode. Existing cards and their editor-entered details are never changed.
export function nextWeekCompetitiveDanceRows(previousWeek, nextWeek, partnerships, cast, existingDances) {
  if (!previousWeek?.is_complete || previousWeek.is_season_finale || !nextWeek
      || nextWeek.is_complete || Number(nextWeek.number) !== Number(previousWeek.number) + 1) return [];

  const castById = new Map((cast || []).map((member) => [member.id, member]));
  const existingPairIds = new Set((existingDances || [])
    .filter((dance) => dance.kind === 'competitive').map((dance) => dance.partnership_id));
  const nextSortOrder = Math.max(0, ...(existingDances || []).map((dance) => Number(dance.sort_order) || 0)) + 1;
  return (partnerships || []).filter((pair) => {
    const star = castById.get(pair.star_id);
    const pro = castById.get(pair.pro_id);
    return pair.active === true && !existingPairIds.has(pair.id)
      && star?.role === 'Star' && pro?.role === 'Pro'
      && !star.eliminated_week_id && !pro.eliminated_week_id;
  }).sort((a, b) => castById.get(a.star_id).name.localeCompare(castById.get(b.star_id).name))
    .map((pair, index) => ({ week_id: nextWeek.id, kind: 'competitive',
      partnership_id: pair.id, sort_order: nextSortOrder + index }));
}
