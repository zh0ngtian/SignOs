import test from 'node:test';
import assert from 'node:assert/strict';
import { checkIPAExists } from '../src/availability.mjs';

const url = 'https://files.example/App.ipa';

test('availability follows public HTTPS redirects with HEAD only', async () => {
  const calls = [];
  await checkIPAExists(url, async (target, init) => {
    calls.push([target, init.method]);
    assert.equal(init.redirect, 'manual');
    return target === url ? new Response(null, { status: 302, headers: { Location: '/download.ipa' } }) : new Response(null, { status: 200 });
  });
  assert.deepEqual(calls, [[url, 'HEAD'], ['https://files.example/download.ipa', 'HEAD']]);
});

for (const unsupported of [405, 501]) {
  for (const status of [200, 206]) {
    test(`HEAD ${unsupported} falls back to a cancelled one-byte GET (${status})`, async () => {
      const calls = []; let cancelled = false;
      await checkIPAExists(url, async (target, init) => {
        calls.push(init.method);
        if (init.method === 'HEAD') return new Response(null, { status: unsupported });
        assert.equal(init.headers.Range, 'bytes=0-0');
        return new Response(new ReadableStream({ cancel() { cancelled = true; } }), { status });
      });
      assert.deepEqual(calls, ['HEAD', 'GET']);
      assert.equal(cancelled, true, 'even a host ignoring Range must not have its body consumed');
    });
  }
}

test('missing and inaccessible files fail without GET; transient failures remain retryable', async () => {
  for (const status of [401, 403, 404, 410, 429, 503]) {
    let calls = 0;
    await assert.rejects(checkIPAExists(url, async (target, init) => {
      calls++; assert.equal(init.method, 'HEAD');
      return new Response(null, { status });
    }), { code: status >= 429 ? 'UPSTREAM_UNAVAILABLE' : 'DOWNLOAD_INACCESSIBLE', retryable: status >= 429 });
    assert.equal(calls, 1);
  }
});

test('availability rejects invalid or unsafe redirects and redirect loops', async () => {
  for (const location of ['http://files.example/app.ipa', 'https://127.0.0.1/app.ipa', 'https://example.local/app.ipa']) {
    await assert.rejects(checkIPAExists(url, async () => new Response(null, { status: 302, headers: { Location: location } })), { code: 'INVALID_URL' });
  }
  await assert.rejects(checkIPAExists(url, async () => new Response(null, { status: 302 })), { code: 'BAD_REDIRECT' });
  let calls = 0;
  await assert.rejects(checkIPAExists(url, async () => {
    calls++; return new Response(null, { status: 302, headers: { Location: url } });
  }), { code: 'BAD_REDIRECT' });
  assert.equal(calls, 6);
});
