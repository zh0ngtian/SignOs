import { gunzipSync } from 'node:zlib';
import { encodeIconPNG } from './png.mjs';

const fail = code => { throw new Error(code); };
const text = a => new TextDecoder('utf-8', { fatal: true }).decode(a).split('\0')[0];
function slice(a, p, n) { if (!Number.isSafeInteger(p + n) || p < 0 || n < 0 || p + n > a.length) fail('INVALID_CAR_RANGE'); return a.subarray(p, p + n); }
const view = a => new DataView(a.buffer, a.byteOffset, a.byteLength);

// BOM trees associate the plist's logical icon name with rendition keys. This
// avoids choosing an unrelated image, an alternate icon, or an atlas by size.
export function extractCARIcon(bytes, names, makeLZFSE) {
  if (text(slice(bytes, 0, 8)) !== 'BOMStore') fail('INVALID_CAR');
  const v = view(bytes), index = slice(bytes, v.getUint32(16), v.getUint32(20)), iv = view(index), count = iv.getUint32(0);
  if (count > 100000 || count * 8 + 4 > index.length) fail('CAR_BLOCK_LIMIT');
  const block = id => { if (id >= count) fail('INVALID_CAR_BLOCK'); return slice(bytes, iv.getUint32(4 + id * 8), iv.getUint32(8 + id * 8)); };
  const vars = slice(bytes, v.getUint32(24), v.getUint32(28)), vv = view(vars), variables = new Map();
  let p = 4; const variableCount = vv.getUint32(0); if (variableCount > 10000) fail('CAR_VARIABLE_LIMIT');
  for (let i = 0; i < variableCount; i++) { const header = slice(vars, p, 5), id = view(header).getUint32(0), n = header[4]; variables.set(text(slice(vars, p + 5, n)), id); p += 5 + n; }
  const named = name => { if (!variables.has(name)) fail('MISSING_CAR_BLOCK'); return block(variables.get(name)); };
  const header = named('CARHEADER'), magic = text(slice(header, 0, 4));
  if (!['RATC', 'CTAR'].includes(magic)) fail('INVALID_CAR_HEADER');
  const le = magic === 'RATC', u16 = (a, p) => view(slice(a, p, 2)).getUint16(0, le), u32 = (a, p) => view(slice(a, p, 4)).getUint32(0, le);
  const four = (a, p) => { const s = text(slice(a, p, 4)); return le ? [...s].reverse().join('') : s; };
  function tree(name) {
    const header = named(name), hv = view(header);
    if (text(slice(header, 0, 4)) !== 'tree' || header.length < 21 || (header[20] & 4)) fail('INVALID_CAR_TREE');
    const expected = hv.getUint32(16); if (expected > 100000) fail('CAR_TREE_LIMIT');
    let id = hv.getUint32(8); const seen = new Set(), out = [];
    while (id) {
      if (seen.has(id)) fail('CAR_TREE_CYCLE'); seen.add(id);
      const node = block(id), nv = view(node), leaf = nv.getUint16(0), n = nv.getUint16(2);
      if (node.length < 12 + n * 8 || ![0, 1].includes(leaf) || out.length + n > 100000) fail('INVALID_CAR_NODE');
      if (!leaf) { if (!n) fail('INVALID_CAR_NODE'); id = nv.getUint32(12); continue; }
      for (let i = 0; i < n; i++) out.push({ value: block(nv.getUint32(12 + i * 8)), key: block(nv.getUint32(16 + i * 8)) });
      id = nv.getUint32(4);
    }
    if (out.length !== expected) fail('INVALID_CAR_TREE_COUNT');
    return out;
  }
  const format = named('KEYFORMAT'), types = [], typeCount = u32(format, 8);
  if (typeCount > 64) fail('CAR_KEY_LIMIT');
  for (let i = 0; i < typeCount; i++) types.push(u32(format, 12 + i * 4));
  const iconIDs = new Set();
  for (const { key, value } of tree('FACETKEYS')) {
    if (!names.includes(text(key))) continue;
    const n = u16(value, 4); if (n > 64) fail('CAR_FACET_LIMIT');
    for (let i = 0; i < n; i++) if (u16(value, 6 + i * 4) === 17) iconIDs.add(u16(value, 8 + i * 4));
  }
  const candidates = [];
  for (const { key, value } of tree('RENDITIONS')) {
    const attributes = new Map(types.map((type, i) => [type, u16(key, i * 2)]));
    if (!iconIDs.has(attributes.get(17)) || (attributes.get(7) ?? 0) !== 0) continue;
    if (value.length < 180 || four(value, 0) !== 'CTSI') fail('INVALID_CAR_CSI');
    const width = u32(value, 12), height = u32(value, 16), start = 180 + 4 * u32(value, 172) + u32(value, 168);
    const payload = slice(value, start, value.length - start);
    // Packed references carry no bitmap; their standalone variants are tried.
    if (!width || width !== height || width > 2048 || payload.length < 16 || four(payload, 0) !== 'CELM') continue;
    candidates.push({ width, height, payload, format: four(value, 24), name: text(slice(value, 40, 128)), idiom: attributes.get(15) ?? 0 });
  }
  // Prefer a usable phone rendition near display resolution; fallback to a
  // larger rendition if its codec is the only supported representation.
  candidates.sort((a, b) => (a.idiom === 1 ? 0 : 1) - (b.idiom === 1 ? 0 : 1) || Math.abs(a.width - 256) - Math.abs(b.width - 256));
  let decoder, error;
  for (const c of candidates) try {
    if (!['ARGB', 'GA8 '].includes(c.format)) fail('CAR_PIXEL_FORMAT_UNSUPPORTED');
    const channels = c.format === 'ARGB' ? 4 : 2, rowBytes = c.width * channels, maximumRow = Math.ceil(rowBytes / 256) * 256;
    const compression = u32(c.payload, 8), data = c.payload.subarray(16);
    const decompress = (input, height) => {
      const maximum = maximumRow * height;
      if (compression === 0) return input;
      if (compression === 2) return new Uint8Array(gunzipSync(input, { maxOutputLength: maximum }));
      if (compression === 4) { decoder ??= makeLZFSE(); return decoder(input, maximum); }
      fail('CAR_COMPRESSION_UNSUPPORTED');
    };
    const pixels = new Uint8Array(rowBytes * c.height);
    const copy = (decoded, rows, destRow) => {
      const stride = decoded.length / rows;
      if (!Number.isInteger(stride) || stride < rowBytes || stride > maximumRow) fail('INVALID_CAR_PIXELS');
      for (let y = 0; y < rows; y++) pixels.set(decoded.subarray(y * stride, y * stride + rowBytes), (destRow + y) * rowBytes);
    };
    if (data[0] === 75 && data[1] === 67 && data[2] === 66 && data[3] === 67) {
      let at = 0, rows = 0, chunks = 0;
      while (rows < c.height) {
        const chunk = slice(data, at, 20), cv = view(chunk), h = cv.getUint32(12, true), size = cv.getUint32(16, true);
        if (text(chunk.subarray(0, 4)) !== 'KCBC' || !h || h > c.height - rows || ++chunks > 256) fail('INVALID_CAR_CHUNK');
        copy(decompress(slice(data, at + 20, size), h), h, rows); rows += h; at += 20 + size;
      }
      if (at !== data.length) fail('INVALID_CAR_CHUNK');
    } else copy(decompress(data, c.height), c.height, 0);
    const rgba = new Uint8Array(c.width * c.height * 4);
    for (let i = 0; i < c.width * c.height; i++) {
      const p = i * channels, q = i * 4;
      rgba[q] = pixels[p + (channels === 4 ? 2 : 0)]; rgba[q + 1] = pixels[p + (channels === 4 ? 1 : 0)]; rgba[q + 2] = pixels[p]; rgba[q + 3] = pixels[p + channels - 1];
    }
    return { ...encodeIconPNG(rgba, c.width, c.height, true), rendition: c.name };
  } catch (e) { error = e; }
  throw error ?? new Error('CAR_PRIMARY_ICON_NOT_FOUND');
}
