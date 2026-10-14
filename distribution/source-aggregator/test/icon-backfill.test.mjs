import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { build } from 'esbuild';
import fixtures from './fixtures.mjs';
import { parseIPA } from '../src/ipa.mjs';

test('An unchanged GitHub IPA refreshes notes and backfills its icon without duplicating history or losing SHA-256', async () => {
  const wasm = readFileSync(new URL('../vendor/lzfse/decoder.wasm', import.meta.url)).toString('base64');
  const bundle = await build({ entryPoints: [new URL('../src/catalog.mjs', import.meta.url).pathname], bundle: true, write: false, format: 'esm', platform: 'node', plugins: [{ name: 'node-harness', setup(build) {
    build.onResolve({ filter: /^cloudflare:workers$/ }, () => ({ path: 'durable', namespace: 'harness' }));
    build.onResolve({ filter: /decoder\.wasm$/ }, () => ({ path: 'decoder', namespace: 'harness' }));
    build.onLoad({ filter: /.*/, namespace: 'harness' }, ({ path }) => ({ contents: path === 'durable' ? 'export class DurableObject {}' : `export default new WebAssembly.Module(Buffer.from('${wasm}', 'base64'));` }));
  } }] });
  const { Catalog } = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);
  const bytes = Buffer.from(fixtures.find(f => f.id === 'icon-car-lzfse').base64, 'base64');
  const url = 'https://fixtures.example/App.ipa', date = '2026-10-11T00:00:00Z';
  let ranges = 0, releaseNotes = '新版中文更新说明';
  const fetcher = async (input, init) => {
    if (String(input).startsWith('https://api.github.com/')) return Response.json([{ id: 123, tag_name: 'v1', body: releaseNotes, draft: false, prerelease: false, published_at: date, assets: [{ id: 1, name: 'App.ipa', size: bytes.length, browser_download_url: url, updated_at: date }] }]);
    ranges++;
    const spec = init.headers.Range, suffix = /^bytes=-(\d+)$/.exec(spec), exact = /^bytes=(\d+)-(\d+)$/.exec(spec);
    const start = suffix ? Math.max(0, bytes.length - Number(suffix[1])) : Number(exact[1]), end = suffix ? bytes.length - 1 : Number(exact[2]);
    return new Response(bytes.subarray(start, end + 1), { status: 206, headers: { 'Content-Range': `bytes ${start}-${end}/${bytes.length}`, ETag: '"same-ipa"' } });
  };
  const inspection = await parseIPA(url, fetcher, { extractIcon: false }); delete inspection.icon;
  const id = '11111111-1111-1111-1111-111111111111';
  const current = { metadata: inspection.metadata, inspection, downloadURL: url, fingerprint: `123:1:${date}:${bytes.length}`, sha256: 'a'.repeat(64), date, notes: '旧版更新说明' };
  const history = [{ ...current, downloadURL: 'https://fixtures.example/previous.ipa' }];
  const data = { revision: 1, settings: { id: 'test' }, entries: [{ id, revision: 1, published: true, config: { kind: 'github', repository: 'owner/repo', assetPattern: 'App.ipa' }, current, history }], jobs: [{ id: 'job', entryId: id, entryRevision: 1, status: 'queued', attempts: 0, nextAt: 0 }] };
  const values = new Map([['catalog', data]]); let ready;
  const ctx = { blockConcurrencyWhile(callback) { ready = callback(); }, storage: { async get(k) { return values.get(k); }, async put(k, v) { values.set(k, v); }, async delete(k) { values.delete(k); }, async setAlarm() {}, async getAlarm() { return null; }, async deleteAlarm() {} } };
  const previousFetch = globalThis.fetch; globalThis.fetch = fetcher;
  try {
    const catalog = new Catalog(ctx, {}); await ready; ranges = 0;
    await catalog.alarm();
    assert.equal(data.entries[0].status, 'succeeded');
    assert.equal(data.entries[0].history.length, 1);
    assert.equal(data.entries[0].current.sha256, 'a'.repeat(64));
    assert.equal(data.entries[0].current.notes, releaseNotes);
    assert.equal(data.entries[0].history[0].notes, '旧版更新说明');
    assert.equal(data.entries[0].current.inspection.iconExtractionVersion, 1);
    assert.match(catalog.publicDocument('https://source.example').apps[0].iconURL, /\/app-icons\/[a-f0-9]{64}\.png$/);
    assert.ok(ranges > 0);
    releaseNotes = '同一版本修订后的中文说明'; values.delete('github:owner/repo');
    ranges = 0; await catalog.schedule(data.entries[0]); data.jobs.find(j => j.status === 'queued').nextAt = 0; await catalog.alarm();
    assert.equal(data.entries[0].history.length, 1);
    assert.equal(ranges, 0, 'unchanged fully inspected IPAs must not download the CAR again');
    assert.equal(data.entries[0].current.notes, releaseNotes);
    assert.equal(data.entries[0].current.sha256, 'a'.repeat(64));
    assert.equal(catalog.publicDocument('https://source.example').apps[0].versionDescription, releaseNotes);
    assert.equal(data.entries[0].history[0].notes, '旧版更新说明');
  } finally { globalThis.fetch = previousFetch; }
});
