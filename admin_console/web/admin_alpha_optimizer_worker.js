/* Opt-in review copy only. Never returns an animation or an alpha mismatch. */
'use strict';

const fourcc = (b, p) => String.fromCharCode(...b.subarray(p, p + 4));
const crcTable = Array.from({length: 256}, (_, n) => {
  for (let i = 0; i < 8; i++) n = (n & 1) ? (n >>> 1) ^ 0xedb88320 : n >>> 1;
  return n >>> 0;
});
function crc(b, start, end) {
  let c = 0xffffffff;
  for (let i = start; i < end; i++) c = crcTable[(c ^ b[i]) & 255] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function pngSize(b) {
  const sig = [137,80,78,71,13,10,26,10];
  if (b.length < 57 || sig.some((n, i) => b[i] !== n)) return null;
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let p = 8, first = true, data = false, endedData = false, palette = false, trns = false;
  let width = 0, height = 0, color = -1;
  while (p + 12 <= b.length) {
    const n = v.getUint32(p), type = fourcc(b, p + 4);
    if (n > b.length - p - 12 || crc(b, p + 4, p + 8 + n) !== v.getUint32(p + 8 + n)) return null;
    if (first) {
      if (type !== 'IHDR' || n !== 13) return null;
      width = v.getUint32(p + 8); height = v.getUint32(p + 12); color = b[p + 17];
      if (!width || !height || b[p + 16] !== 8 || ![0,2,3,4,6].includes(color) ||
          b[p + 18] !== 0 || b[p + 19] !== 0 || b[p + 20] !== 0) return null;
      first = false;
    } else if (type === 'PLTE') {
      if (data || palette || n < 3 || n > 768 || n % 3 || [0,4].includes(color)) return null;
      palette = true;
    } else if (type === 'tRNS') {
      if (data || trns || ![0,2,3].includes(color) || (color === 3 && !palette)) return null;
      if ((color === 0 && n !== 2) || (color === 2 && n !== 6) || (color === 3 && (n < 1 || n > 256))) return null;
      trns = true;
    } else if (type === 'IDAT') {
      if (endedData || (color === 3 && !palette)) return null;
      data = true;
    } else if (type === 'IEND') {
      return n === 0 && data && p + 12 === b.length ? {width, height, mime:'image/png'} : null;
    } else {
      return null; // Includes ICC, EXIF, text, APNG, unknown and second IHDR.
    }
    if (data && type !== 'IDAT') endedData = true;
    p += n + 12;
  }
  return null;
}

function webpSize(b, allowOutputIcc = false) {
  if (b.length < 20 || fourcc(b, 0) !== 'RIFF' || fourcc(b, 8) !== 'WEBP') return null;
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  if (v.getUint32(4, true) + 8 !== b.length) return null;
  let p = 12, width = 0, height = 0, vp8x = false, image = false, alpha = false, icc = false;
  while (p + 8 <= b.length) {
    const type = fourcc(b, p), n = v.getUint32(p + 4, true), start = p + 8;
    const end = start + n, padded = end + (n & 1);
    if (end > b.length || padded > b.length || ((n & 1) && b[end] !== 0)) return null;
    if (type === 'VP8X') {
      if (p !== 12 || vp8x || n !== 10 || (b[start] & (allowOutputIcc ? 0xcf : 0xef)) !== 0 ||
          b[start+1] || b[start+2] || b[start+3]) return null;
      vp8x = true;
      width = 1 + b[start+4] + (b[start+5] << 8) + (b[start+6] << 16);
      height = 1 + b[start+7] + (b[start+8] << 8) + (b[start+9] << 16);
    } else if (type === 'ICCP') {
      if (!allowOutputIcc || !vp8x || icc || alpha || image || n < 1 || n > 4096) return null;
      icc = true;
    } else if (type === 'ALPH') {
      if (!vp8x || alpha || image || n < 1) return null;
      alpha = true;
    } else if (type === 'VP8 ' || type === 'VP8L') {
      if (image || (type === 'VP8 ' ? n < 10 : n < 5)) return null;
      let w, h;
      if (type === 'VP8 ') {
        if ((b[start] & 1) || b[start+3] !== 0x9d || b[start+4] !== 0x01 || b[start+5] !== 0x2a) return null;
        w = v.getUint16(start+6, true) & 0x3fff; h = v.getUint16(start+8, true) & 0x3fff;
      } else {
        if (alpha || b[start] !== 0x2f) return null;
        const bits = v.getUint32(start+1, true);
        if ((bits >>> 29) !== 0) return null;
        w = 1 + (bits & 0x3fff); h = 1 + ((bits >>> 14) & 0x3fff);
      }
      if (!w || !h || (vp8x && (width !== w || height !== h))) return null;
      width = w; height = h; image = true;
    } else {
      return null; // Includes animation, profiles, metadata and unknown chunks.
    }
    p = padded;
  }
  return p === b.length && image ? {width, height, mime:'image/webp'} : null;
}

self.onmessage = async event => {
  let source, candidate;
  try {
    if (!(event.data instanceof ArrayBuffer)) throw new Error('input');
    const bytes = new Uint8Array(event.data);
    if (bytes.length > 10 * 1024 * 1024) throw new Error('limit');
    const info = pngSize(bytes) || webpSize(bytes);
    if (!info || info.width * info.height > 8000000 ||
        typeof OffscreenCanvas !== 'function' || typeof createImageBitmap !== 'function') throw new Error('unsupported');
    source = await createImageBitmap(new Blob([bytes], {type:info.mime}));
    if (source.width !== info.width || source.height !== info.height) throw new Error('dimensions');
    const scale = Math.min(1, 1600 / Math.max(source.width, source.height));
    const width = Math.max(1, Math.round(source.width * scale));
    const height = Math.max(1, Math.round(source.height * scale));
    const canvas = new OffscreenCanvas(width, height);
    const ctx = canvas.getContext('2d', {alpha:true, willReadFrequently:true});
    if (!ctx) throw new Error('canvas');
    ctx.drawImage(source, 0, 0, width, height);
    const original = ctx.getImageData(0, 0, width, height).data;
    let best = null;
    for (const quality of [0.9, 0.82, 0.75]) {
      ctx.clearRect(0, 0, width, height);
      ctx.drawImage(source, 0, 0, width, height);
      const blob = await canvas.convertToBlob({type:'image/webp', quality});
      if (blob.type !== 'image/webp' || blob.size >= bytes.length || blob.size > 5 * 1024 * 1024) continue;
      candidate = await createImageBitmap(blob);
      if (candidate.width !== width || candidate.height !== height) throw new Error('output dimensions');
      ctx.clearRect(0, 0, width, height);
      ctx.drawImage(candidate, 0, 0);
      const output = ctx.getImageData(0, 0, width, height).data;
      let difference = 0, samples = 0, alphaMatches = true;
      for (let i = 0; i < original.length; i += 4) {
        if (original[i+3] !== output[i+3]) { alphaMatches = false; break; }
        if (original[i+3] !== 0) {
          difference += Math.abs(original[i]-output[i]) + Math.abs(original[i+1]-output[i+1]) + Math.abs(original[i+2]-output[i+2]);
          samples += 3;
        }
      }
      candidate.close(); candidate = null;
      if (!alphaMatches || (samples && difference / samples > 15)) continue;
      const result = await blob.arrayBuffer();
      // Browser-created WebP may contain its own small sRGB ICC profile. Input
      // ICC remains unsupported; the output pixels were checked above.
      if (!webpSize(new Uint8Array(result), true)) continue;
      if (best === null || result.byteLength < best.byteLength) best = result;
      if (best.byteLength <= 512 * 1024) break;
    }
    if (best === null) throw new Error('no acceptable saving');
    self.postMessage(best, [best]);
  } catch (_) {
    self.postMessage(null);
  } finally {
    if (source) source.close();
    if (candidate) candidate.close();
  }
};
