import { airingWindows, easternDateTime } from './market-prediction-model.js?v=20260930-avatar-frame-v78';

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

export function isDraftAiringLocked(weeks, now = Date.now()) {
  const clock = easternDateTime(now);
  return weeks.some((week) => !week.is_complete && airingWindows(week).some(([start]) =>
    clock >= shiftedEasternClock(start, -15)));
}
