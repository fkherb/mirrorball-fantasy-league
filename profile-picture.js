const MAX_SOURCE_BYTES = 30 * 1024 * 1024;
const MAX_UPLOAD_BYTES = 2 * 1024 * 1024;
const MAX_DIMENSION = 1024;
const SOURCE_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']);

export function isSupportedPictureFile(file) {
  const type = String(file?.type || '').toLowerCase();
  const extension = String(file?.name || '').toLowerCase().match(/\.([a-z0-9]+)$/)?.[1];
  return SOURCE_TYPES.has(type) || (!type && ['jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'].includes(extension));
}

export function scaledPictureDimensions(width, height, maxDimension = MAX_DIMENSION) {
  const scale = Math.min(1, maxDimension / Math.max(width, height));
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) };
}

async function decodePicture(file) {
  if (typeof createImageBitmap === 'function') {
    try { return await createImageBitmap(file, { imageOrientation: 'from-image' }); } catch { /* Try the browser's image decoder below. */ }
  }
  const url = URL.createObjectURL(file);
  try {
    const image = new Image();
    image.src = url;
    await image.decode();
    return image;
  } finally {
    URL.revokeObjectURL(url);
  }
}

function jpegBlob(canvas, quality) {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => blob ? resolve(blob) : reject(new Error('This browser could not convert that photo.')), 'image/jpeg', quality);
  });
}

export async function prepareProfilePicture(file) {
  if (!isSupportedPictureFile(file)) throw new Error('Choose a JPEG, PNG, WebP, or HEIC camera photo.');
  if (file.size > MAX_SOURCE_BYTES) throw new Error('Choose a photo under 30 MB.');
  let image;
  try { image = await decodePicture(file); } catch { throw new Error('This browser could not read that photo. Try exporting it as JPEG.'); }
  try {
    const width = image.width || image.naturalWidth;
    const height = image.height || image.naturalHeight;
    if (!width || !height) throw new Error('This photo has no readable dimensions.');
    const size = scaledPictureDimensions(width, height);
    const canvas = document.createElement('canvas');
    canvas.width = size.width;
    canvas.height = size.height;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('This browser could not prepare that photo.');
    context.fillStyle = '#ffffff';
    context.fillRect(0, 0, size.width, size.height);
    context.drawImage(image, 0, 0, size.width, size.height);
    for (const quality of [0.86, 0.72, 0.58]) {
      const blob = await jpegBlob(canvas, quality);
      if (blob.size <= MAX_UPLOAD_BYTES) return new File([blob], 'profile-photo.jpg', { type: 'image/jpeg' });
    }
    throw new Error('This photo could not be reduced below 2 MB. Try a smaller photo.');
  } finally {
    image.close?.();
  }
}
