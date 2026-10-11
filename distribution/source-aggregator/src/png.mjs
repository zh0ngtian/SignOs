import { deflateSync, inflateSync, inflateRawSync } from 'node:zlib';
import { crc32 } from './crc.mjs';

const signature = Uint8Array.of(137, 80, 78, 71, 13, 10, 26, 10);
const fail = () => { throw new Error('INVALID_ICON_PNG'); };
const be = (a, p) => new DataView(a.buffer, a.byteOffset, a.byteLength).getUint32(p);
const join = parts => Buffer.concat(parts.map(p => Buffer.from(p)));
function chunk(type, data) {
  const body = join([new TextEncoder().encode(type), data]);
  const out = Buffer.alloc(body.length + 8);
  out.writeUInt32BE(data.length); out.set(body, 4); out.writeUInt32BE(crc32(body), out.length - 4);
  return out;
}

export function encodeIconPNG(pixels, width, height, premultiplied = false) {
  if (!width || !height || width > 2048 || height > 2048 || pixels.length !== width * height * 4) fail();
  // Small source icons retain their resolution. Larger icons use an area
  // average, preserving thin strokes while keeping each storage value bounded.
  let size = Math.min(256, width, height);
  for (;;) {
    const scan = Buffer.alloc(size * (1 + size * 4));
    for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
      const x0 = Math.floor(x * width / size), x1 = Math.floor((x + 1) * width / size);
      const y0 = Math.floor(y * height / size), y1 = Math.floor((y + 1) * height / size);
      let r = 0, g = 0, b = 0, a = 0, n = 0;
      for (let sy = y0; sy < y1; sy++) for (let sx = x0; sx < x1; sx++) {
        const p = (sy * width + sx) * 4, alpha = pixels[p + 3];
        const factor = premultiplied ? 1 : alpha / 255;
        r += pixels[p] * factor; g += pixels[p + 1] * factor; b += pixels[p + 2] * factor; a += alpha; n++;
      }
      const p = y * (size * 4 + 1) + 1 + x * 4;
      scan[p] = a ? Math.min(255, Math.round(r * 255 / a)) : 0;
      scan[p + 1] = a ? Math.min(255, Math.round(g * 255 / a)) : 0;
      scan[p + 2] = a ? Math.min(255, Math.round(b * 255 / a)) : 0;
      scan[p + 3] = Math.round(a / n);
    }
    const header = Buffer.alloc(13); header.writeUInt32BE(size); header.writeUInt32BE(size, 4); header[8] = 8; header[9] = 6;
    const png = join([signature, chunk('IHDR', header), chunk('IDAT', deflateSync(scan)), chunk('IEND', new Uint8Array())]);
    if (png.length <= 96 * 1024) return { png: new Uint8Array(png), width: size, height: size };
    size = Math.floor(size / 2);
  }
}

export function normalizeIconPNG(bytes) {
  if (bytes.length < 33 || !signature.every((v, i) => bytes[i] === v)) fail();
  let width, height, color, cgbi = false, ended = false, palette, alpha;
  const parts = [];
  for (let p = 8; p < bytes.length;) {
    if (p + 12 > bytes.length) fail();
    const length = be(bytes, p), end = p + 12 + length;
    if (end > bytes.length) fail();
    const type = new TextDecoder().decode(bytes.subarray(p + 4, p + 8)), data = bytes.subarray(p + 8, end - 4);
    if (crc32(bytes.subarray(p + 4, end - 4)) !== be(bytes, end - 4)) fail();
    if (type === 'CgBI') cgbi = true;
    if (type === 'IHDR') {
      if (width !== undefined || length !== 13) fail();
      width = be(data, 0); height = be(data, 4); color = data[9];
      if (!width || !height || width !== height || width > 2048 || data[8] !== 8 || ![2, 3, 6].includes(color) || data[10] || data[11] || data[12]) fail();
    }
    if (type === 'PLTE') palette = data;
    if (type === 'tRNS') alpha = data;
    if (type === 'IDAT') parts.push(data);
    if (type === 'IEND') { ended = true; if (end !== bytes.length || length) fail(); }
    p = end;
  }
  if (!ended || !width || !parts.length || (color === 3 && (!palette || palette.length % 3))) fail();
  const channels = color === 6 ? 4 : color === 2 ? 3 : 1, row = width * channels;
  const raw = (cgbi ? inflateRawSync : inflateSync)(join(parts), { maxOutputLength: (row + 1) * height });
  if (raw.length !== (row + 1) * height) fail();
  const decoded = Buffer.alloc(row * height);
  const paeth = (a, b, c) => { const p = a + b - c, x = Math.abs(p - a), y = Math.abs(p - b), z = Math.abs(p - c); return x <= y && x <= z ? a : y <= z ? b : c; };
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (row + 1)]; if (filter > 4) fail();
    for (let x = 0; x < row; x++) {
      const p = y * row + x, a = x >= channels ? decoded[p - channels] : 0, b = y ? decoded[p - row] : 0, c = y && x >= channels ? decoded[p - row - channels] : 0;
      decoded[p] = raw[y * (row + 1) + 1 + x] + [0, a, b, Math.floor((a + b) / 2), paeth(a, b, c)][filter];
    }
  }
  const rgba = Buffer.alloc(width * height * 4);
  for (let i = 0; i < width * height; i++) {
    const p = i * channels, q = i * 4;
    if (color === 3) {
      const index = decoded[p]; if (index * 3 + 2 >= palette.length) fail();
      rgba.set(palette.subarray(index * 3, index * 3 + 3), q); rgba[q + 3] = alpha?.[index] ?? 255;
    } else {
      rgba[q] = decoded[p + (cgbi ? 2 : 0)]; rgba[q + 1] = decoded[p + 1]; rgba[q + 2] = decoded[p + (cgbi ? 0 : 2)]; rgba[q + 3] = channels === 4 ? decoded[p + 3] : 255;
    }
  }
  return encodeIconPNG(rgba, width, height, cgbi);
}
