/* Dedicated worker for safe, best-effort optimization of new admin photos. */
'use strict';

function ascii(bytes, start, count) {
  return String.fromCharCode(...bytes.subarray(start, start + count));
}

function pngInfo(bytes) {
  if (bytes.length < 33 || ascii(bytes, 1, 3) !== 'PNG' || bytes[0] !== 137) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const width = view.getUint32(16), height = view.getUint32(20);
  // Alpha-bearing and palette PNGs are kept verbatim.
  if (bytes[25] !== 0 && bytes[25] !== 2) return null;
  let offset = 8;
  while (offset + 12 <= bytes.length) {
    const length = view.getUint32(offset), type = ascii(bytes, offset + 4, 4);
    if (length > bytes.length - offset - 12) return null;
    if (type === 'acTL' || type === 'iCCP' || type === 'tRNS') return null;
    offset += length + 12;
    if (type === 'IEND') return { width, height, mime: 'image/png' };
  }
  return null;
}

function exifIsUpright(bytes, start, length) {
  if (length < 14 || ascii(bytes, start, 6) !== 'Exif\x00\x00') return false;
  const tiff = start + 6, end = start + length;
  const byteOrder = ascii(bytes, tiff, 2);
  if (byteOrder !== 'II' && byteOrder !== 'MM') return false;
  const little = byteOrder === 'II';
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (tiff + 8 > end || view.getUint16(tiff + 2, little) !== 42) return false;
  const ifd = tiff + view.getUint32(tiff + 4, little);
  if (ifd < tiff || ifd + 2 > end) return false;
  const count = view.getUint16(ifd, little);
  if (count > 1024 || ifd + 2 + count * 12 > end) return false;
  for (let i = 0; i < count; i++) {
    const entry = ifd + 2 + i * 12;
    if (view.getUint16(entry, little) !== 274) continue;
    if (view.getUint16(entry + 2, little) !== 3 || view.getUint32(entry + 4, little) !== 1) return false;
    return view.getUint16(entry + 8, little) === 1;
  }
  return true;
}

function jpegInfo(bytes) {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  let offset = 2, info = null;
  while (offset + 3 < bytes.length) {
    if (bytes[offset++] !== 0xff) return null;
    while (offset < bytes.length && bytes[offset] === 0xff) offset++;
    const marker = bytes[offset++];
    if (marker === 0xd9) break;
    if (marker === 0xda) return info;
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.length) return null;
    const length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) return null;
    // Keep non-upright, unknown EXIF, ICC and Adobe colour data unchanged.
    if (marker === 0xe1 && !exifIsUpright(bytes, offset + 2, length - 2)) return null;
    if (marker === 0xe2 || marker === 0xee) return null;
    if ([0xc0, 0xc1, 0xc2].includes(marker)) {
      if (length < 8) return null;
      const height = (bytes[offset + 3] << 8) | bytes[offset + 4];
      const width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      const components = bytes[offset + 7];
      if (components !== 1 && components !== 3) return null;
      info = { width, height, mime: 'image/jpeg' };
    }
    offset += length;
  }
  return null;
}

self.onmessage = async (event) => {
  try {
    if (!(event.data instanceof ArrayBuffer)) throw new Error('input');
    const bytes = new Uint8Array(event.data);
    const info = jpegInfo(bytes) || pngInfo(bytes);
    if (!info || !info.width || !info.height || info.width * info.height > 20000000 ||
        typeof createImageBitmap !== 'function' || typeof OffscreenCanvas !== 'function') {
      self.postMessage(null); return;
    }
    const image = await createImageBitmap(new Blob([bytes], { type: info.mime }));
    try {
      if (image.width !== info.width || image.height !== info.height) {
        self.postMessage(null); return;
      }
      const scale = Math.min(1, 1600 / Math.max(image.width, image.height));
      const width = Math.max(1, Math.round(image.width * scale));
      const height = Math.max(1, Math.round(image.height * scale));
      const canvas = new OffscreenCanvas(width, height);
      const context = canvas.getContext('2d', { alpha: false });
      if (!context) { self.postMessage(null); return; }
      context.drawImage(image, 0, 0, width, height);
      const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.88 });
      if (blob.type !== 'image/jpeg' || blob.size >= bytes.length) { self.postMessage(null); return; }
      const output = await blob.arrayBuffer();
      self.postMessage(output, [output]);
    } finally {
      image.close();
    }
  } catch (_) {
    self.postMessage(null);
  }
};
