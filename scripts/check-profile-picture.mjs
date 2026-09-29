import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { isSupportedPictureFile, scaledPictureDimensions } from '../profile-picture.js';

assert(isSupportedPictureFile({ name: 'camera.heic', type: 'image/heic' }));
assert(isSupportedPictureFile({ name: 'camera.HEIF', type: '' }));
assert(isSupportedPictureFile({ name: 'camera.jpeg', type: 'image/jpeg' }));
assert(!isSupportedPictureFile({ name: 'not-a-photo.svg', type: 'image/svg+xml' }));
assert.deepEqual(scaledPictureDimensions(4032, 3024), { width: 1024, height: 768 });
assert.deepEqual(scaledPictureDimensions(3024, 4032), { width: 768, height: 1024 });
assert.deepEqual(scaledPictureDimensions(500, 400), { width: 500, height: 400 });

const ui = await readFile(new URL('../ui.js', import.meta.url), 'utf8');
assert.match(ui, /prepareProfilePicture\(file\)/);
assert.match(ui, /if \(pictureProcessing\) return/);

console.log('Camera photo acceptance and resizing verified.');
