// Keep R2 private. Only published source files are exposed by this read-only Worker.
export function parseRange(value, size) {
  if (!value) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  // Unsupported/multiple ranges are ignored, as permitted by HTTP.
  if (!match || (!match[1] && !match[2])) return null;
  let start, end;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0 || !size) return false;
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] ? Number(match[2]) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || end < start) return false;
    end = Math.min(end, size - 1);
  }
  return { offset: start, length: end - start + 1 };
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    const certificateType = {
      '/certificates/signos-ca.mobileconfig': 'application/x-apple-aspen-config',
      '/certificates/signos-ca.cer': 'application/pkix-cert',
    }[path];
    const key = path === '/source.json' || path === '/appstore'
      ? 'source.json'
      : certificateType || /^\/files\/[A-Za-z0-9._-]+\.(ipa|png)$/.test(path) ? path.slice(1) : null;
    if (!key) return new Response('Not found', { status: 404 });
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    const metadata = await env.SOURCE.head(key);
    if (!metadata) return new Response('Not found', { status: 404 });
    const headers = new Headers({
      'Content-Type': certificateType || (key === 'source.json' ? 'application/json; charset=utf-8'
        : key.endsWith('.png') ? 'image/png' : 'application/octet-stream'),
      'Cache-Control': key === 'source.json' || certificateType ? 'no-store' : 'public, max-age=31536000, immutable',
      'X-Content-Type-Options': 'nosniff',
      'Accept-Ranges': 'bytes',
      'ETag': metadata.httpEtag,
      'Last-Modified': metadata.uploaded.toUTCString(),
    });
    const matches = request.headers.get('If-None-Match');
    if (matches && matches.split(',').some(tag => tag.trim() === '*' || tag.trim().replace(/^W\//, '') === metadata.httpEtag)) {
      return new Response(null, { status: 304, headers });
    }
    const ifRange = request.headers.get('If-Range');
    const rangeAllowed = !ifRange || ifRange === metadata.httpEtag || ifRange === headers.get('Last-Modified');
    const range = request.method === 'GET' && rangeAllowed
      ? parseRange(request.headers.get('Range'), metadata.size) : null;
    if (range === false) {
      headers.set('Content-Range', `bytes */${metadata.size}`);
      return new Response(null, { status: 416, headers });
    }
    headers.set('Content-Length', String(range ? range.length : metadata.size));
    if (range) headers.set('Content-Range', `bytes ${range.offset}-${range.offset + range.length - 1}/${metadata.size}`);
    if (request.method === 'HEAD') return new Response(null, { headers });
    // Stream directly: never buffer an IPA inside the Worker's memory.
    const object = await env.SOURCE.get(key, {
      onlyIf: { etagMatches: metadata.etag },
      ...(range ? { range } : {}),
    });
    if (!object) return new Response('Not found', { status: 404 });
    if (!object.body) return new Response('Object changed; retry request', { status: 503, headers: { 'Retry-After': '1' } });
    return new Response(object.body, { status: range ? 206 : 200, headers });
  },
};
