import assert from 'node:assert/strict';
import { test } from 'node:test';
import { Miniflare, Headers as RuntimeHeaders } from 'miniflare';
// Miniflare's RPC bridge serializes its own Headers implementation.
globalThis.Headers = RuntimeHeaders;
import { cleanup, trimVersions, listObjects, GRACE_MS, LOCK_KEY, STATE_KEY } from '../src/retention.mjs';

const base = 'https://source.example';
const document = (count = 12) => {
  const versions = Array.from({ length: count }, (_, i) => ({
    downloadURL: `${base}/files/v${i}.ipa`, date: `2026-09-${String(i + 1).padStart(2, '0')}T00:00:00Z`,
  }));
  return { sourceURL: base + '/source.json', iconURL: base + '/files/shared.png',
    apps: [{ ...versions[0], versions }] }; // Deliberate rollback: oldest release is current.
};
async function fixture(t, count = 12) {
  const mf = new Miniflare({ modules: true, script: 'export default {fetch(){return new Response("ok")}}',
    compatibilityDate: '2026-05-22', r2Buckets: ['SOURCE'] });
  t.after(() => mf.dispose());
  const bucket = await mf.getR2Bucket('SOURCE');
  await bucket.put('source.json', JSON.stringify(document(count)));
  for (let i = 0; i < count; i++) await bucket.put(`files/v${i}.ipa`, 'ipa' + i);
  await bucket.put('files/shared.png', 'shared icon');
  await bucket.put('private/keep.ipa', 'private');
  return bucket;
}

test('retain current rollback plus newest nine releases', () => {
  const result = trimVersions(document());
  assert.equal(result.apps[0].versions.length, 10);
  assert.deepEqual(result.apps[0].versions.map(v => v.downloadURL.split('/').at(-1)),
    ['v0.ipa', 'v11.ipa', 'v10.ipa', 'v9.ipa', 'v8.ipa', 'v7.ipa', 'v6.ipa', 'v5.ipa', 'v4.ipa', 'v3.ipa']);
});

test('real R2 binding: retirement grace, shared references, private files and atomic lock', async t => {
  const b = await fixture(t), now = Date.now();
  const first = await cleanup(b, now);
  assert.equal(first.trimmed, true);
  assert.equal(first.deleted, 0);
  assert.equal(first.pending, 2);
  assert.equal((await cleanup(b, now + GRACE_MS - 1)).deleted, 0);
  assert.equal((await cleanup(b, now + GRACE_MS)).deleted, 2);
  for (const key of ['files/v0.ipa', 'files/shared.png', 'private/keep.ipa']) assert.ok(await b.head(key));
  for (const key of ['files/v1.ipa', 'files/v2.ipa', LOCK_KEY]) assert.equal(await b.head(key), null);
  await b.put(LOCK_KEY, JSON.stringify({ owner: 'another-publisher' }));
  const before = await (await b.get(STATE_KEY)).text();
  assert.deepEqual(await cleanup(b, now), { status: 'busy', deleted: 0 });
  assert.equal(await (await b.get(STATE_KEY)).text(), before);
  assert.ok(await b.head(LOCK_KEY));
});

test('rereferenced and reuploaded files get a fresh grace period', async t => {
  const b = await fixture(t, 1), now = Date.now();
  await b.put('files/orphan.ipa', 'orphan');
  await b.put('files/new.png', 'old');
  await cleanup(b, now);
  const source = document(1);
  source.apps[0].iconURL = base + '/files/orphan.ipa';
  await b.put('source.json', JSON.stringify(source));
  await b.put('files/new.png', 'replacement');
  assert.equal((await cleanup(b, now + GRACE_MS)).deleted, 0);
  const state = await (await b.get(STATE_KEY)).json();
  assert.equal(state.pending['files/orphan.ipa'], undefined);
  assert.equal(state.pending['files/new.png'].since, now + GRACE_MS);
  await b.put('source.json', JSON.stringify(document(1)));
  await cleanup(b, now + GRACE_MS + 1);
  assert.equal((await (await b.get(STATE_KEY)).json()).pending['files/orphan.ipa'].since, now + GRACE_MS + 1);
});

test('missing references stop cleanup and release lock', async t => {
  const b = await fixture(t, 1);
  await b.delete('files/v0.ipa');
  await assert.rejects(cleanup(b), /Missing referenced object/);
  assert.equal(await b.head(STATE_KEY), null);
  assert.equal(await b.head(LOCK_KEY), null);
});

test('manifest changes stop deletions even if grace expired', async t => {
  const b = await fixture(t, 1), now = Date.now();
  await b.put('files/orphan.ipa', 'orphan');
  await cleanup(b, now);
  const changed = new Proxy(b, { get(target, key) {
    if (key === 'head') return async () => ({ etag: 'changed-elsewhere' });
    const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
  } });
  await assert.rejects(cleanup(changed, now + GRACE_MS), /Manifest changed/);
  assert.ok(await b.head('files/orphan.ipa'));
});

test('inventory follows all pages and rejects broken cursors', async () => {
  const calls = [];
  const objects = await listObjects({ async list(options) {
    calls.push(options.cursor);
    return options.cursor ? { objects: [{ key: 'b' }], truncated: false } :
      { objects: [{ key: 'a' }], truncated: true, cursor: 'next' };
  } });
  assert.deepEqual(objects.map(o => o.key), ['a', 'b']);
  assert.deepEqual(calls, [undefined, 'next']);
  await assert.rejects(listObjects({ list: async () => ({ objects: [], truncated: true }) }), /Incomplete/);
});
