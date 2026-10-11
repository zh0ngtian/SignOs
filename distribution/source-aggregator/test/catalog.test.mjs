import test from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import fixtures from './fixtures.mjs';
import { build } from 'esbuild';

test('Durable catalog publishes only parsed apps, preserves old versions on failure, and enforces auth/revisions', async () => {
  const bytes = Buffer.from(fixtures.find(x => x.id === 'binary-deflate').base64, 'base64');
  let apiCalls = 0;
  const token = 'test-management-token-with-at-least-32-characters';
  const bundle = await build({ entryPoints: [new URL('../src/index.mjs', import.meta.url).pathname], bundle: true, write: false, format: 'esm', platform: 'node', external: ['cloudflare:workers'], loader: { '.png': 'binary' } });
  const mf = new Miniflare(convertV4MiniflareOptions({
    modules: true, script: bundle.outputFiles[0].text,
    compatibilityDate: '2026-05-22', compatibilityFlags: ['nodejs_compat'],
    durableObjects: { CATALOG: { className: 'Catalog', useSQLite: true } },
    bindings: { ADMIN_TOKEN: token, SOURCE_ID: 'test', SOURCE_NAME: 'Test Source', SOURCE_IDENTIFIER: 'com.example.source' },
    outboundService: async request => {
      const url = new URL(request.url);
      if (url.hostname === 'api.github.com') {
        apiCalls++;
        return Response.json([{ id: 123, tag_name: 'v1', draft: false, prerelease: false, published_at: '2026-10-11T00:00:00Z', assets: [
          { id: 1, name: 'App.ipa', size: bytes.length, browser_download_url: 'https://fixtures.example/App.ipa', updated_at: '2026-10-11T00:00:00Z' },
          { id: 2, name: 'App-SE.ipa', size: bytes.length, browser_download_url: 'https://fixtures.example/App-SE.ipa', updated_at: '2026-10-11T00:00:00Z' },
        ] }], { headers: { ETag: '"release"' } });
      }
      if (url.pathname === '/bad.ipa') return new Response('missing', { status: 404 });
      const range = request.headers.get('Range'), suffix = /^bytes=-(\d+)$/.exec(range), exact = /^bytes=(\d+)-(\d+)$/.exec(range);
      const start = suffix ? Math.max(0, bytes.length - Number(suffix[1])) : Number(exact[1]);
      const end = suffix ? bytes.length - 1 : Number(exact[2]);
      return new Response(bytes.subarray(start, end + 1), { status: 206, headers: { 'Content-Range': `bytes ${start}-${end}/${bytes.length}`, ETag: '"fixture"' } });
    },
  }));
  const call = async (path, method = 'GET', body, secret = token) => {
    const response = await mf.dispatchFetch(`https://source.example${path}`, { method, headers: { Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
    return { status: response.status, data: await response.json() };
  };
  const waitFor = async (id, status) => {
    for (let i = 0; i < 100; i++) {
      const state = (await call('/api/catalog')).data;
      const entry = state.entries.find(e => e.id === id);
      if (entry.status === status) return state;
      await new Promise(r => setTimeout(r, 50));
    }
    assert.fail(`entry did not reach ${status}`);
  };
  try {
    assert.equal((await call('/api/catalog', 'GET', null, 'invalid')).status, 401);
    assert.equal((await call('/source.json')).data.apps.length, 0);
    const create = await call('/api/entries', 'POST', { revision: 0, config: { kind: 'url', url: 'https://fixtures.example/App.ipa' } });
    assert.equal(create.status, 201);
    const id = create.data.entry.id;
    assert.equal((await call('/source.json')).data.apps.length, 0);
    const ready = await waitFor(id, 'ready');
    assert.equal(ready.entries[0].current.metadata.name, '验证 & Range');
    assert.equal((await call(`/api/entries/${id}/confirm`, 'POST', { revision: 0 })).status, 409);
    assert.equal((await call(`/api/entries/${id}/confirm`, 'POST', { revision: ready.revision })).status, 200);
    const source = (await call('/source.json')).data;
    assert.equal(source.apps[0].downloadURL, 'https://fixtures.example/App.ipa');
    assert.equal(source.apps[0].bundleIdentifier, 'com.example.range');
    const discovery = await call('/api/discover', 'POST', { config: { kind: 'github', repository: 'owner/repo' } });
    assert.equal(discovery.data.candidates.length, 2);
    const state = (await call('/api/catalog')).data;
    const ambiguous = await call('/api/entries', 'POST', { revision: state.revision, config: { kind: 'github', repository: 'owner/repo', assetPattern: '*.ipa' } });
    const failed = await waitFor(ambiguous.data.entry.id, 'failed');
    assert.equal(failed.entries.find(e => e.id === ambiguous.data.entry.id).error.code, 'ASSET_AMBIGUOUS');
    assert.equal(apiCalls, 1, 'subscriptions share a release cache');
    assert.equal((await call('/source.json')).data.apps.length, 1);
    const edited = await call(`/api/entries/${id}`, 'PATCH', { revision: failed.revision, config: { kind: 'url', url: 'https://fixtures.example/bad.ipa' } });
    assert.equal(edited.status, 200);
    const broken = await waitFor(id, 'failed');
    assert.equal(broken.entries.find(e => e.id === id).error.code, 'DOWNLOAD_INACCESSIBLE');
    assert.equal((await call('/source.json')).data.apps[0].downloadURL, 'https://fixtures.example/App.ipa');
    assert.equal((await call('/api/entries', 'POST', { revision: broken.revision, config: { kind: 'url', url: 'https://fixtures.example/App.ipa' }, metadata: { name: 'fake' } })).data.error.code, 'MANUAL_METADATA_DISABLED');
    const backup = (await call('/api/export')).data;
    assert.equal(JSON.stringify(backup).includes(token), false);
    const beforeRestore = (await call('/api/catalog')).data;
    const tampered = structuredClone(backup); tampered.entries[0].current.metadata.name = 'edited manually';
    assert.equal((await call('/api/restore', 'POST', { revision: beforeRestore.revision, backup: tampered })).data.error.code, 'INVALID_BACKUP');
    // Reordered JSON keys must still verify, as native JSON serializers reorder objects.
    const reordered = Object.fromEntries(Object.entries(backup).reverse());
    assert.equal((await call('/api/restore', 'POST', { revision: beforeRestore.revision, backup: reordered })).status, 200);
    const restored = (await call('/api/catalog')).data;
    assert.equal(restored.entries[0].id, id);
    assert.equal(restored.entries[0].current.metadata.name, '验证 & Range');
    assert.equal(restored.entries[0].published, true);
    assert.equal((await call(`/api/entries/${id}/attest`, 'POST', { revision: restored.revision, sha256: '0'.repeat(64) })).data.error.code, 'DIGEST_UNVERIFIED');
    const newToken = 'rotated-test-token-with-at-least-32-characters';
    assert.equal((await call('/api/token', 'POST', { token: newToken })).status, 200);
    assert.equal((await call('/api/catalog')).status, 401);
    assert.equal((await call('/api/catalog', 'GET', null, newToken)).status, 200);
  } finally { await mf.dispose(); }
});
