const clamp = (value, fallback, min, max) => {
  const number = Number(value);
  return Number.isFinite(number) ? Math.min(max, Math.max(min, number)) : fallback;
};

// A star's profile keeps a separate framing choice for each pro partner.
export function couplePhotoFrameFor(star, proId) {
  const saved = star?.profile_details?._couple_photo_frames?.[proId] || {};
  return {
    x: clamp(saved.x, 50, 0, 100),
    y: clamp(saved.y, 10, 0, 100),
    zoom: clamp(saved.zoom, 1, 1, 2.5),
  };
}

export function couplePhotoStyle(frame) {
  const x = clamp(frame?.x, 50, 0, 100);
  const y = clamp(frame?.y, 10, 0, 100);
  const zoom = clamp(frame?.zoom, 1, 1, 2.5);
  return `object-position:${x}% ${y}%;transform:scale(${zoom});transform-origin:${x}% ${y}%`;
}
