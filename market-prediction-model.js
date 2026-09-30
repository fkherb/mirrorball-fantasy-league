export const SEASON_MARKET_LABELS = Object.freeze({
  winner: 'Chance to win',
  second: 'Chance of 2nd place',
  third: 'Chance of 3rd place',
  top_three: 'Chance of Top 3',
  finalist: 'Chance of making the finals',
});

export function isActivePrediction(row, now = Date.now(), maxAgeMinutes = 35) {
  return ['active', 'open'].includes(row?.market_status)
    && Number.isFinite(Number(row.percent))
    && Number(row.percent) >= 0 && Number(row.percent) <= 100
    && Number.isFinite(Date.parse(row.fetched_at))
    && now - Date.parse(row.fetched_at) < maxAgeMinutes * 60 * 1000;
}

export function activePartnershipPredictionRows(rows, partnerships, cast) {
  const activeStars = new Set((partnerships || []).filter((pair) => pair.active !== false)
    .filter((pair) => {
      const star = (cast || []).find((member) => member.id === pair.star_id);
      const pro = (cast || []).find((member) => member.id === pair.pro_id);
      return star?.role === 'Star' && pro?.role === 'Pro'
        && !star.eliminated_week_id && !pro.eliminated_week_id;
    }).map((pair) => pair.star_id));
  return rows.filter((row) => activeStars.has(row.cast_member_id));
}

export function relativePredictionPosition(row, rows, now = Date.now()) {
  const comparable = rows.filter((item) => item.market_kind === row.market_kind
    && (row.market_kind !== 'elimination' || item.week_id === row.week_id)
    && isActivePrediction(item, now)).map((item) => Number(item.percent)).sort((a, b) => a - b);
  if (comparable.length < 2) return 0.5;
  const value = Number(row.percent);
  const lower = comparable.filter((percent) => percent < value).length;
  const equal = comparable.filter((percent) => percent === value).length;
  return (lower + (equal - 1) / 2) / (comparable.length - 1);
}

export function seasonPredictionsFor(starId, rows, now = Date.now()) {
  if (!starId) return [];
  return rows.filter((row) => row.cast_member_id === starId
      && Object.hasOwn(SEASON_MARKET_LABELS, row.market_kind)
      && isActivePrediction(row, now))
    .map((row) => ({ ...row, relative_position: relativePredictionPosition(row, rows, now) }))
    .sort((a, b) => Number(b.percent) - Number(a.percent)
      || Object.keys(SEASON_MARKET_LABELS).indexOf(a.market_kind)
        - Object.keys(SEASON_MARKET_LABELS).indexOf(b.market_kind));
}

export function weeklyPredictionFor(starId, week, rows, now = Date.now()) {
  if (!starId || !week || week.is_complete || week.is_finale
      || !week.elimination_predictions_enabled || easternDateTime(now) >= finalAiringEnd(week)) return null;
  const row = rows.find((item) => item.cast_member_id === starId
    && item.week_id === week.id && item.market_kind === 'elimination'
    && isActivePrediction(item, now, isWeekAiring(week, now) ? 12 : 35)) || null;
  return row ? { ...row, relative_position: relativePredictionPosition(row, rows, now) } : null;
}

export function easternDateTime(now = Date.now()) {
  if (typeof now === 'string' && /^\d{4}-\d\d-\d\d$/.test(now)) return `${now}T00:00`;
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
    hourCycle: 'h23' }).formatToParts(new Date(now));
  const value = (part) => parts.find((item) => item.type === part)?.value;
  return `${value('year')}-${value('month')}-${value('day')}T${value('hour')}:${value('minute')}`;
}

export function airingWindows(week) {
  const windows = [];
  if (week?.air_date) windows.push([`${week.air_date}T${String(week.air_start_time || '20:00').slice(0, 5)}`,
    `${week.air_date}T${String(week.air_end_time || '22:00').slice(0, 5)}`]);
  if (week?.second_air_date) windows.push([`${week.second_air_date}T${String(week.second_air_start_time || '20:00').slice(0, 5)}`,
    `${week.second_air_date}T${String(week.second_air_end_time || '22:00').slice(0, 5)}`]);
  return windows;
}

export function finalAiringEnd(week) {
  return airingWindows(week).at(-1)?.[1] || '';
}

export function isWeekAiring(week, now = Date.now()) {
  const clock = easternDateTime(now);
  return airingWindows(week).some(([start, end]) => clock >= start && clock < end);
}

export function nextPredictionWeek(weeks, now = Date.now()) {
  const clock = easternDateTime(now);
  return [...weeks].sort((a, b) => Number(a.number) - Number(b.number))
    .find((week) => finalAiringEnd(week) > clock) || null;
}

export function predictionPercent(value) {
  const number = Number(value);
  return `${Number.isInteger(number) ? number : number.toFixed(1)}%`;
}
