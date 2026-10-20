import test from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { build } from 'esbuild';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import fixtures from './fixtures.mjs';
import { privateAssetTransport, downloadPrivateAsset, privateRepository } from '../src/github-assets.mjs';
import { releaseCandidates } from '../src/releases.mjs';

const githubToken = 'github-secret-kept-only-on-the-server';
const asset = { repository: 'owner/private', id: 1, name: 'App.ipa', size: 10 };
const api = 'https://api.github.com/repos/owner/private/releases/assets/1';
const cdn = 'https://release-assets.githubusercontent.com/test/App.ipa?signature=temporary-secret';

test('private inspection reuses a transient CDN resolution and sends only GitHub credentials to the API', async () => {
  const requests = [];
  const transport = privateAssetTransport(asset, { GITHUB_TOKEN: githubToken }, async (url, init) => {
    requests.push({ url, headers: new Headers(init.headers) });
    if (url === api) return new Response(null, { status: 302, headers: { Location: cdn } });
    return new Response('x', { status: 206, headers: { 'Content-Range': 'bytes 0-0/1' } });
  });
  for (let i = 0; i < 2; i++) await (await transport(null, {
    headers: { Range: 'bytes=0-0', 'If-Range': '"immutable-etag"', Authorization: 'Bearer source-token', Cookie: 'session=private' },
  })).body.cancel();
  assert.equal(requests.filter(r => r.url === api).length, 1);
  assert.equal(requests[0].headers.get('Authorization'), `Bearer ${githubToken}`);
  assert.equal(requests[0].headers.get('Accept'), 'application/octet-stream');
  for (const request of requests.slice(1)) {
    assert.equal(request.url, cdn);
    assert.equal(request.headers.get('Authorization'), null);
    assert.equal(request.headers.get('Cookie'), null);
    assert.equal(request.headers.get('Range'), 'bytes=0-0');
    assert.equal(request.headers.get('If-Range'), '"immutable-etag"');
    assert.equal(request.headers.get('Accept-Encoding'), 'identity');
  }
  assert.equal(transport.finalHost, 'release-assets.githubusercontent.com');
});

test('private assets reject missing credentials, untrusted redirects and invalid repository responses', async () => {
  await assert.rejects(privateAssetTransport(asset, {})(null), { code: 'GITHUB_TOKEN_REQUIRED' });
  for (const location of ['https://evil.example/file', 'https://api.github.com/another', 'http://release-assets.githubusercontent.com/file']) {
    await assert.rejects(privateAssetTransport(asset, { GITHUB_TOKEN: githubToken }, async () =>
      new Response(null, { status: 302, headers: { Location: location } }))(null));
  }
  await assert.rejects(privateRepository('owner/private', { GITHUB_TOKEN: githubToken }, async () => Response.json({})), { code: 'GITHUB_RESPONSE_INVALID' });
  await assert.rejects(privateRepository('owner/private', { GITHUB_TOKEN: githubToken }, async () => new Response(null, { status: 404 })), { code: 'GITHUB_UNAVAILABLE' });
  assert.throws(() => privateAssetTransport({ ...asset, id: -1 }, {}), { code: 'INVALID_GITHUB_ASSET' });
  assert.throws(() => privateAssetTransport({ ...asset, name: '../App.ipa' }, {}), { code: 'INVALID_GITHUB_ASSET' });
});

test('suffix ranges become explicit intervals using the immutable GitHub attachment size', async () => {
  const ranges = [];
  const transport = privateAssetTransport(asset, { GITHUB_TOKEN: githubToken }, async (_url, init) => {
    ranges.push(new Headers(init.headers).get('Range'));
    return new Response(null, { status: 206 });
  });
  await transport(null, { headers: { Range: 'bytes=-3' } });
  await transport(null, { headers: { Range: 'bytes=-65557' } });
  assert.deepEqual(ranges, ['bytes=7-9', 'bytes=0-9']);
  await assert.rejects(transport(null, { headers: { Range: 'bytes=-0' } }), { code: 'INVALID_RANGE' });
});

test('private timeouts identify API versus CDN without exposing tokens or signed addresses', async () => {
  for (const phase of ['github-asset-api', 'github-asset-cdn']) {
    const transport = privateAssetTransport(asset, { GITHUB_TOKEN: githubToken }, async url => {
      if (url === api && phase === 'github-asset-cdn') return new Response(null, { status: 302, headers: { Location: cdn } });
      throw new DOMException('sensitive signed address: ' + cdn, 'TimeoutError');
    });
    await assert.rejects(transport(null, { headers: { Range: 'bytes=0-0' } }), error => {
      assert.equal(error.code, 'DOWNLOAD_TIMEOUT');
      assert.equal(error.details.phase, phase);
      assert.equal(error.details.range, 'bytes=0-0');
      assert.equal(JSON.stringify(error).includes('temporary-secret'), false);
      assert.equal(JSON.stringify(error).includes(githubToken), false);
      return true;
    });
  }
});

test('release cache retains repository visibility across cache hits and conditional refresh', async () => {
  const values = new Map();
  const cache = { get: async k => values.get(k), put: async (k, v) => values.set(k, v) };
  let calls = 0;
  const transport = async (url, init) => {
    calls++;
    assert.equal(new Headers(init.headers).get('Authorization'), `Bearer ${githubToken}`);
    if (!url.includes('/releases')) return Response.json({ private: true });
    if (init.headers['If-None-Match']) return new Response(null, { status: 304 });
    return Response.json([{ id: 1, tag_name: 'v1', published_at: '2026-10-20T00:00:00Z',
      assets: [{ id: 1, name: 'App.ipa', size: 10, browser_download_url: 'https://github.com/owner/private/releases/download/v1/App.ipa' }] }], { headers: { ETag: '"listing"' } });
  };
  const config = { repository: 'owner/private' }, env = { GITHUB_TOKEN: githubToken };
  const first = await releaseCandidates(config, env, cache, transport);
  assert.deepEqual(first[0].privateAsset, asset);
  assert.deepEqual(await releaseCandidates(config, env, cache, transport), first);
  assert.equal(calls, 2);
  values.get('github:owner/private').checkedAt = 0;
  assert.deepEqual(await releaseCandidates(config, env, cache, transport), first);
  assert.equal(calls, 4);
  delete values.get('github:owner/private').requiresAuthentication;
  assert.deepEqual(await releaseCandidates(config, env, cache, transport), first, 'old caches acquire repository visibility before reuse');
  assert.equal(calls, 6);
});

test('authenticated access to a public repository retains its original direct download URL', async () => {
  const cache = { get: async () => null, put: async () => {} };
  const url = 'https://github.com/owner/public/releases/download/v1/App.ipa';
  const candidates = await releaseCandidates({ repository: 'owner/public' }, { GITHUB_TOKEN: githubToken }, cache, async input =>
    input.includes('/releases') ? Response.json([{ id: 1, tag_name: 'v1', published_at: '2026-10-20T00:00:00Z',
      assets: [{ id: 1, name: 'App.ipa', size: 10, browser_download_url: url }] }]) : Response.json({ private: false }));
  assert.equal(candidates[0].url, url);
  assert.equal(candidates[0].privateAsset, undefined);
});

test('proxy streams without leaking upstream headers and cancels HEAD bodies even for direct API responses', async () => {
  let canceled = false;
  const response = await downloadPrivateAsset(new Request('https://source.example/downloads/file', { method: 'HEAD' }), asset,
    { GITHUB_TOKEN: githubToken }, async () => new Response(new ReadableStream({ cancel() { canceled = true; } }), {
      headers: { 'Content-Length': '123456789', 'Set-Cookie': 'private', Location: cdn, 'X-Upstream-Secret': githubToken },
    }));
  assert.equal(canceled, true);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Content-Length'), '123456789');
  assert.equal(response.headers.get('Location'), null);
  assert.equal(response.headers.get('Set-Cookie'), null);
  assert.equal(response.headers.get('X-Upstream-Secret'), null);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal((await response.arrayBuffer()).byteLength, 0);
});

test('Worker publishes a private IPA through an anonymous, bounded download route and retains history', async () => {
  const bytes = Buffer.from(fixtures.find(f => f.id === 'icon-png').base64, 'base64');
  const digest = createHash('sha256').update(bytes).digest('hex');
  const admin = 'test-source-management-token-at-least-32-characters';
  let latest = 1, unavailable = false, assetCalls = 0, isPrivate = true;
  const outbound = [];
  const releases = id => ({ id, tag_name: `v${id}`, draft: false, prerelease: false, body: `版本 ${id} 的中文说明`,
    published_at: `2026-10-${20 + id}T00:00:00Z`, assets: [{ id, name: 'App.ipa', size: bytes.length, digest: `sha256:${digest}`,
      browser_download_url: `https://github.com/owner/private/releases/download/v${id}/App.ipa`, updated_at: `2026-10-${20 + id}T00:00:00Z` }] });
  const bundle = await build({ entryPoints: [new URL('../src/index.mjs', import.meta.url).pathname], bundle: true, write: false,
    format: 'esm', platform: 'node', external: ['cloudflare:workers'], loader: { '.png': 'binary' },
    plugins: [{ name: 'wasm', setup(b) { b.onResolve({ filter: /decoder\.wasm$/ }, () => ({ path: './decoder.wasm', external: true })); } }] });
  const mf = new Miniflare(convertV4MiniflareOptions({ modulesRoot: '/worker', modules: [
    { type: 'ESModule', path: '/worker/index.mjs', contents: bundle.outputFiles[0].text },
    { type: 'CompiledWasm', path: '/worker/decoder.wasm', contents: readFileSync(new URL('../vendor/lzfse/decoder.wasm', import.meta.url)) },
  ], compatibilityDate: '2026-05-22', compatibilityFlags: ['nodejs_compat'],
  durableObjects: { CATALOG: { className: 'Catalog', useSQLite: true } },
  bindings: { ADMIN_TOKEN: admin, GITHUB_TOKEN: githubToken, SOURCE_ID: 'test' },
  outboundService: async request => {
    const url = new URL(request.url);
    outbound.push({ host: url.hostname, path: url.pathname, authorization: request.headers.get('Authorization') });
    if (url.hostname === 'api.github.com') {
      assert.equal(request.headers.get('Authorization'), `Bearer ${githubToken}`);
      if (url.pathname === '/repos/owner/private') return Response.json({ private: isPrivate });
      if (url.pathname === '/repos/owner/private/releases') return Response.json([releases(latest)]);
      if (url.pathname.includes('/releases/tags/')) return Response.json(releases(Number(url.pathname.split('/').at(-1).slice(1))));
      if (url.pathname.includes('/releases/assets/')) {
        assetCalls++;
        return new Response(null, { status: unavailable ? 404 : 302, headers: { Location: cdn } });
      }
    }
    assert.equal(url.hostname, 'release-assets.githubusercontent.com');
    assert.equal(request.headers.get('Authorization'), null);
    assert.equal(request.headers.get('Cookie'), null);
    if (request.headers.get('If-None-Match') === '"fixture"') return new Response(null, { status: 304, headers: { ETag: '"fixture"' } });
    const range = request.headers.get('Range'), suffix = /^bytes=-(\d+)$/.exec(range), exact = /^bytes=(\d+)-(\d*)$/.exec(range);
    const start = suffix ? Math.max(0, bytes.length - Number(suffix[1])) : exact ? Number(exact[1]) : 0;
    const end = exact && exact[2] ? Math.min(Number(exact[2]), bytes.length - 1) : bytes.length - 1;
    if (start >= bytes.length) return new Response(cdn, { status: 416, headers: { 'Content-Range': `bytes */${bytes.length}`, 'Content-Length': String(cdn.length) } });
    return new Response(request.method === 'HEAD' ? null : bytes.subarray(start, end + 1), { status: range ? 206 : 200,
      headers: { 'Content-Length': String(end - start + 1), ETag: '"fixture"', 'Accept-Ranges': 'bytes',
        ...(range ? { 'Content-Range': `bytes ${start}-${end}/${bytes.length}` } : {}), 'Set-Cookie': 'do-not-forward' } });
  } }));
  const call = async (path, method = 'GET', body) => {
    const response = await mf.dispatchFetch(`https://source.example${path}`, { method,
      headers: { Authorization: `Bearer ${admin}`, 'Content-Type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
    assert.ok(response.ok, `${path}: ${response.status}`);
    return response.json();
  };
  const waitFor = async (id, status, predicate = () => true) => {
    let last;
    for (let i = 0; i < 100; i++) {
      const state = await call('/api/catalog');
      last = state.entries.find(e => e.id === id);
      if (last.status === status && predicate(last)) return state;
      await new Promise(r => setTimeout(r, 50));
    }
    assert.fail(`entry did not reach ${status}: ${JSON.stringify(last?.error)}`);
  };
  try {
    const created = await call('/api/entries', 'POST', { revision: 0, config: { kind: 'github', repository: 'owner/private', assetPattern: 'App.ipa' } });
    const id = created.entry.id;
    const ready = await waitFor(id, 'ready');
    const path = `/downloads/${id}/1/App.ipa`;
    assert.equal((await mf.dispatchFetch(`https://source.example${path}`)).status, 404, 'unconfirmed entries are never downloadable');
    await call(`/api/entries/${id}/confirm`, 'POST', { revision: ready.revision });
    const source = await (await mf.dispatchFetch('https://source.example/source.json')).json();
    const downloadURL = source.apps[0].downloadURL;
    assert.equal(downloadURL, `https://source.example${path}`);
    assert.equal(JSON.stringify(source).includes('signature='), false);
    assert.equal((await mf.dispatchFetch('https://source.example/api/catalog')).status, 401, 'management still requires a Token');
    const full = await mf.dispatchFetch(downloadURL, { headers: { Authorization: 'Bearer arbitrary-client-token', Cookie: 'client-secret' } });
    assert.equal(full.status, 200);
    assert.deepEqual(Buffer.from(await full.arrayBuffer()), bytes);
    assert.equal(full.headers.get('Location'), null);
    assert.equal(full.headers.get('Set-Cookie'), null);
    assert.equal(full.headers.get('Cache-Control'), 'no-store');
    const head = await mf.dispatchFetch(downloadURL, { method: 'HEAD' });
    assert.equal(head.status, 200);
    assert.equal(head.headers.get('Content-Length'), String(bytes.length));
    assert.equal((await head.arrayBuffer()).byteLength, 0);
    for (const [range, expected] of [['bytes=0-0', bytes.subarray(0, 1)], ['bytes=-20', bytes.subarray(-20)], ['bytes=20-', bytes.subarray(20)]]) {
      const partial = await mf.dispatchFetch(downloadURL, { headers: { Range: range, 'If-Range': '"fixture"' } });
      assert.equal(partial.status, 206);
      assert.deepEqual(Buffer.from(await partial.arrayBuffer()), expected);
    }
    assert.equal((await mf.dispatchFetch(downloadURL, { headers: { 'If-None-Match': '"fixture"' } })).status, 304);
    const unsatisfied = await mf.dispatchFetch(downloadURL, { headers: { Range: `bytes=${bytes.length + 1}-` } });
    assert.equal(unsatisfied.status, 416);
    assert.equal(await unsatisfied.text(), '', 'upstream error pages cannot expose the signed CDN URL');
    const previousCalls = assetCalls;
    for (const [url, init, status] of [[downloadURL.replace('/1/', '/999/'), {}, 404], [downloadURL.replace('App.ipa', 'Other.ipa'), {}, 404],
      [downloadURL, { method: 'POST' }, 405], [downloadURL, { headers: { Range: 'bytes=0-1,4-5' } }, 416]]) {
      assert.equal((await mf.dispatchFetch(url, init)).status, status);
    }
    assert.equal(assetCalls, previousCalls, 'forged downloads and invalid ranges never contact GitHub');
    await call(`/api/entries/${id}/attest`, 'POST', { revision: (await call('/api/catalog')).revision, sha256: digest });
    await call(`/api/entries/${id}/sync`, 'POST', {});
    const unchanged = await waitFor(id, 'succeeded');
    assert.equal(unchanged.entries[0].history.length, 0);
    assert.equal(unchanged.entries[0].current.sha256, digest);
    assert.equal(assetCalls, previousCalls, 'unchanged versions reuse the parsed IPA');
    isPrivate = false;
    await call(`/api/entries/${id}/sync`, 'POST', {});
    const publicState = await waitFor(id, 'succeeded');
    assert.equal(publicState.entries[0].current.privateAsset, undefined);
    assert.equal((await call('/source.json')).apps[0].downloadURL, 'https://github.com/owner/private/releases/download/v1/App.ipa');
    isPrivate = true;
    await call(`/api/entries/${id}/sync`, 'POST', {});
    await waitFor(id, 'succeeded');
    assert.equal((await call('/source.json')).apps[0].downloadURL, downloadURL, 'visibility changes update routing without reparsing or losing hashes');
    assert.equal(assetCalls, previousCalls);
    latest = 2;
    await call(`/api/entries/${id}/sync`, 'POST', {});
    const updated = await waitFor(id, 'succeeded');
    assert.equal(updated.entries[0].history.length, 1);
    const versions = (await call('/source.json')).apps[0].versions;
    assert.match(versions[0].downloadURL, /\/2\/App\.ipa$/);
    assert.equal(versions[1].downloadURL, downloadURL);
    assert.equal((await mf.dispatchFetch(downloadURL)).status, 200, 'retained history remains downloadable');
    await call(`/api/entries/${id}/history`, 'POST', { revision: (await call('/api/catalog')).revision,
      versions: [{ downloadURL: 'https://github.com/owner/private/releases/download/v4/App.ipa', date: '2026-10-10T00:00:00Z', sha256: digest }] });
    const imported = await waitFor(id, 'succeeded', e => e.history.length === 2);
    assert.equal(imported.entries[0].history[1].privateAsset.id, 4, 'private historical URLs are resolved and inspected with authentication');
    assert.equal((await mf.dispatchFetch(`https://source.example/downloads/${id}/4/App.ipa`)).status, 200);
    const retainedVersions = (await call('/source.json')).apps[0].versions;
    latest = 3; unavailable = true;
    await call(`/api/entries/${id}/sync`, 'POST', {});
    const failed = await waitFor(id, 'failed');
    assert.equal(failed.entries[0].error.code, 'DOWNLOAD_INACCESSIBLE');
    assert.deepEqual((await call('/source.json')).apps[0].versions, retainedVersions, 'failed updates preserve published versions');
    const serialized = JSON.stringify(await call('/api/catalog'));
    for (const secret of [githubToken, 'temporary-secret', 'signature=']) assert.equal(serialized.includes(secret), false);
    await call(`/api/entries/${id}`, 'DELETE', { revision: (await call('/api/catalog')).revision });
    assert.equal((await mf.dispatchFetch(downloadURL)).status, 404, 'removing a subscription revokes its proxy routes');
    assert.ok(outbound.every(r => r.authorization === null || r.host === 'api.github.com'));
  } finally { await mf.dispose(); }
});
