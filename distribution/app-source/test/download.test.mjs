import assert from 'node:assert/strict';
import { test } from 'node:test';
import worker, { parseRange } from '../src/index.mjs';

const bytes = new TextEncoder().encode('0123456789');
const metadata = { size: bytes.length, etag: 'version1', httpEtag: '"version1"', uploaded: new Date('2026-10-10T00:00:00Z') };
const env = { SOURCE: {
  async head(key) { return key.includes('missing') ? null : metadata; },
  async get(key, options) {
    assert.equal(options.onlyIf.etagMatches, metadata.etag);
    const range = options.range;
    return { ...metadata, body: new Blob([range ? bytes.slice(range.offset, range.offset + range.length) : bytes]).stream() };
  },
} };
const fetch = (headers = {}, method = 'GET', path = '/files/test.ipa') => worker.fetch(new Request(`https://example.com${path}`, { headers, method }), env);

test('full download and HEAD preserve size and stream', async () => {
  const response = await fetch();
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Content-Length'), '10');
  assert.equal(await response.text(), '0123456789');
  const head = await fetch({ Range: 'bytes=0-2' }, 'HEAD');
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('Content-Length'), '10');
  assert.equal(await head.text(), '');
});
test('bounded, open-ended, suffix and unsatisfiable ranges', async () => {
  for (const [value, expected, contentRange] of [
    ['bytes=2-4', '234', 'bytes 2-4/10'],
    ['bytes=7-', '789', 'bytes 7-9/10'],
    ['bytes=-3', '789', 'bytes 7-9/10'],
    ['bytes=8-99', '89', 'bytes 8-9/10'],
  ]) {
    const response = await fetch({ Range: value });
    assert.equal(response.status, 206);
    assert.equal(response.headers.get('Content-Range'), contentRange);
    assert.equal(await response.text(), expected);
  }
  const invalid = await fetch({ Range: 'bytes=10-' });
  assert.equal(invalid.status, 416);
  assert.equal(invalid.headers.get('Content-Range'), 'bytes */10');
  assert.equal(parseRange('bytes=0-1,5-6', 10), null);
});
test('ETag validation and stale If-Range', async () => {
  assert.equal((await fetch({ 'If-None-Match': 'W/"version1"' })).status, 304);
  const response = await fetch({ Range: 'bytes=5-', 'If-Range': '"old"' });
  assert.equal(response.status, 200);
  assert.equal(await response.text(), '0123456789');
});
test('source alias stays fresh; private paths and writes are denied', async () => {
  for (const path of ['/source.json', '/appstore']) {
    const response = await fetch({}, 'GET', path);
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
    assert.equal(response.headers.get('Content-Type'), 'application/json; charset=utf-8');
  }
  for (const path of ['/.publish.lock', '/server.local.json', '/files/missing.ipa', '/files/test.txt']) {
    assert.equal((await fetch({}, 'GET', path)).status, 404);
  }
  assert.equal((await fetch({}, 'PUT')).status, 405);
});
