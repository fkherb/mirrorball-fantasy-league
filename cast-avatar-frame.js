// Small circular cast photos use their own crop, independent of the full
// portrait framing. The values live in the existing profile_details object.
const clamp = (value, fallback, min, max) => {
  const number = Number(value);
  return Number.isFinite(number) ? Math.min(max, Math.max(min, number)) : fallback;
};

export function avatarFrameFor(member) {
  const saved = member?.profile_details?._avatar_frame || {};
  return {
    x: clamp(saved.x, 50, 0, 100),
    y: clamp(saved.y, 50, 0, 100),
    zoom: clamp(saved.zoom, 1, 1, 3),
  };
}

export function avatarImageStyle(member) {
  const { x, y, zoom } = avatarFrameFor(member);
  return `object-position:${x}% ${y}%;transform:scale(${zoom});transform-origin:${x}% ${y}%`;
}
