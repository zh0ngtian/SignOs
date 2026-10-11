import test from 'node:test';
import assert from 'node:assert/strict';
import fixtures from './fixtures.mjs';
import { parseIPA } from '../src/ipa.mjs';
import { publicURL, repository, glob, subscription } from '../src/urls.mjs';

export function rangeTransport(fixture) {
  const bytes = Buffer.from(fixture.base64, 'base64'); let requests = 0;
  return async (_url, init) => {
    requests++;
    if (fixture.behavior === 'ignore') return new Response(bytes, { status: 200 });
    const range = init.headers.Range, suffix = /^bytes=-(\d+)$/.exec(range), exact = /^bytes=(\d+)-(\d+)$/.exec(range);
    const start = suffix ? Math.max(0, bytes.length - Number(suffix[1])) : Number(exact[1]);
    const end = suffix ? bytes.length - 1 : Number(exact[2]);
    const payload = bytes.subarray(start, fixture.behavior === 'truncated' ? end : end + 1);
    return new Response(payload, { status: 206, headers: {
      'Content-Range': `bytes ${fixture.behavior === 'wrong' ? start + 1 : start}-${end}/${bytes.length}`,
      ETag: fixture.behavior === 'changed' && requests > 1 ? '"changed"' : '"fixture"',
    } });
  };
}

for (const fixture of fixtures) {
  test(`Range parser: ${fixture.id}`, async () => {
    const transport = rangeTransport(fixture);
    if (fixture.error) await assert.rejects(parseIPA('https://fixtures.example/app.ipa', transport), e => e.code === fixture.error);
    else {
      const result = await parseIPA('https://fixtures.example/app.ipa', transport);
      assert.deepEqual(result.metadata, fixture.expected);
      assert.equal(result.fullBytes, Buffer.from(fixture.base64, 'base64').length);
      assert.equal(result.downloadedBytes, result.requests.reduce((n, r) => n + r.bytes, 0));
      assert.equal(result.zip64, fixture.id === 'zip64');
    }
  });
}

test('URLs and attachment rules cannot target private hosts or accidentally match checksum files', () => {
  for (const url of ['http://example.com/a.ipa', 'https://127.0.0.1/a.ipa', 'https://[::1]/a', 'https://user:pass@example.com/a', 'https://example.local/a', 'https://example.com:8080/a']) assert.throws(() => publicURL(url));
  assert.equal(repository('https://github.com/zh0ngtian/codex-mobile/'), 'zh0ngtian/codex-mobile');
  assert.equal(glob('CodexMobile-*.ipa', 'CodexMobile-v0.2.150-unsigned.ipa'), true);
  assert.equal(glob('CodexMobile-*.ipa', 'CodexMobile-v0.2.150-unsigned.ipa.sha256'), false);
  assert.equal(glob('UTM-SE.ipa', 'UTM.ipa'), false);
  assert.throws(() => subscription({ kind: 'github', repository: 'owner/repo', assetPattern: '../*.ipa' }));
});

test('Redirects cannot downgrade HTTPS and non-Range bodies are cancelled', async () => {
  await assert.rejects(parseIPA('https://fixtures.example/app.ipa', async () => new Response(null, { status: 302, headers: { Location: 'http://example.com/app.ipa' } })), e => e.code === 'INVALID_URL');
  let cancelled = false;
  await assert.rejects(parseIPA('https://fixtures.example/app.ipa', async () => new Response(new ReadableStream({ cancel() { cancelled = true; } }), { status: 200 })), e => e.code === 'RANGE_UNSUPPORTED');
  assert.equal(cancelled, true);
});
