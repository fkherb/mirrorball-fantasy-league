import { airingWindows, easternDateTime } from './market-prediction-model.js?v=20261006-airing-draft-v96';

function shiftedEasternClock(clock, minutes) {
  const [date, time] = clock.split('T');
  const [year, month, day] = date.split('-').map(Number);
  const [hour, minute] = time.split(':').map(Number);
  return new Date(Date.UTC(year, month - 1, day, hour, minute + minutes)).toISOString().slice(0, 16);
}

export function isTradeAiringLocked(weeks, now = Date.now()) {
  const clock = easternDateTime(now);
  return weeks.some((week) => airingWindows(week).some(([start, end]) =>
    clock >= shiftedEasternClock(start, -120) && clock < shiftedEasternClock(end, 120)));
}

export function isDraftAiringLocked() {
  // Draft turns may continue during an airing. Trade/free-agent locks remain.
  return false;
}
