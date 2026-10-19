import test from 'node:test';
import assert from 'node:assert/strict';
import { releaseCandidates, chooseCandidate } from '../src/releases.mjs';
import { subscription } from '../src/urls.mjs';

function release(id, tag, names, options = {}) {
  return {
    id, tag_name: tag, published_at: `2026-10-${String(id).padStart(2, '0')}T00:00:00Z`,
    draft: false, prerelease: false, body: `Notes for ${tag}`,
    assets: names.map((name, index) => ({
      id: id * 10 + index, name, size: 123,
      browser_download_url: `https://downloads.example/${tag}/${name}`,
    })),
    ...options,
  };
}

function listing(pages) {
  const values = new Map();
  const cache = { get: async key => values.get(key), put: async (key, value) => values.set(key, value) };
  let calls = 0;
  const transport = async url => {
    calls++;
    const page = Number(new URL(url).searchParams.get('page'));
    return Response.json(pages[page - 1], {
      headers: page < pages.length ? { Link: `<https://api.github.com/releases?page=${page + 1}>; rel="next"` } : {},
    });
  };
  return { cache, transport, calls: () => calls };
}

test('finds the newest IPA across empty and Android-only releases and paginated history', async () => {
  const source = listing([
    [release(11, '8.41.3', ['bangumi.apk']), release(10, '8.41.2', [])],
    [release(8, '8.40.2', ['bangumi_v8.40.2.ipa']), release(9, '8.41.1', ['bangumi_v8.41.1.ipa'])],
  ]);
  const config = { repository: 'czy0729/Bangumi' };
  const candidates = await releaseCandidates(config, {}, source.cache, source.transport);
  assert.deepEqual(candidates.map(x => [x.tag, x.name]), [['8.41.1', 'bangumi_v8.41.1.ipa']]);
  assert.equal(candidates[0].notes, 'Notes for 8.41.1');
  assert.equal(candidates[0].releaseId, 9);
  assert.equal(candidates[0].url, 'https://downloads.example/8.41.1/bangumi_v8.41.1.ipa');
  assert.equal(source.calls(), 2);
  assert.deepEqual(await releaseCandidates(config, {}, source.cache, source.transport), candidates);
  assert.equal(source.calls(), 2, 'the cached listing uses the same fallback logic');
});

test('skips nonmatching IPA variants while respecting tag, prerelease and draft rules', async () => {
  const source = listing([[
    release(11, 'ios-draft', ['App.ipa'], { draft: true }),
    release(10, 'android-v10', ['App.ipa']),
    release(9, 'ios-v9', ['App.ipa'], { prerelease: true }),
    release(8, 'ios-v8', ['Other.ipa']),
    release(7, 'ios-v7', ['App.IPA', 'Other.ipa']),
  ]]);
  const config = { repository: 'owner/repo', tagPrefix: 'ios-', assetPattern: 'App.ipa' };
  const candidates = await releaseCandidates(config, {}, source.cache, source.transport);
  assert.deepEqual(candidates.map(x => [x.tag, x.name]), [['ios-v7', 'App.IPA']]);
  const prerelease = await releaseCandidates({ ...config, includePrereleases: true }, {}, source.cache, source.transport);
  assert.equal(prerelease[0].tag, 'ios-v9');
});

test('keeps all matching candidates in the newest qualifying release instead of falling back past ambiguity', async () => {
  const source = listing([[
    release(11, 'v3', []),
    release(10, 'v2', ['App.ipa', 'App-SE.ipa']),
    release(9, 'v1', ['App.ipa']),
  ]]);
  const candidates = await releaseCandidates({ repository: 'owner/repo', assetPattern: 'App*.ipa' }, {}, source.cache, source.transport);
  assert.deepEqual(candidates.map(x => x.tag), ['v2', 'v2']);
  assert.throws(() => chooseCandidate(candidates), { code: 'ASSET_AMBIGUOUS' });
});

test('distinguishes no eligible releases from no matching IPA anywhere in eligible history', async () => {
  const source = listing([[release(11, 'v2', ['App.apk']), release(10, 'v1', ['Other.ipa'])]]);
  await assert.rejects(
    releaseCandidates({ repository: 'owner/repo', tagPrefix: 'missing-' }, {}, source.cache, source.transport),
    { code: 'RELEASE_NOT_FOUND' },
  );
  await assert.rejects(
    releaseCandidates({ repository: 'owner/repo', assetPattern: 'App*.ipa' }, {}, source.cache, source.transport),
    { code: 'ASSET_NOT_FOUND' },
  );
});

test('accepts literal alternative tag prefixes in the existing string config', () => {
  const config = { kind: 'github', repository: 'owner/repo' };
  assert.equal(subscription(config).tagPrefix, '');
  assert.equal(subscription({ ...config, tagPrefix: ' build- ' }).tagPrefix, 'build-');
  const dual = subscription({ ...config, tagPrefix: ' build- | v ' });
  assert.equal(dual.tagPrefix, 'build-|v');
  assert.deepEqual(subscription(JSON.parse(JSON.stringify(dual))), dual, 'client and backup string round trips preserve both prefixes');
  for (const tagPrefix of ['|', '|v', 'build-|', 'build-| |v', 'x'.repeat(101)]) {
    assert.throws(() => subscription({ ...config, tagPrefix }), { code: 'INVALID_RULE' });
  }
});

test('selects either tag family by publication time across pages and cached listings', async () => {
  for (const newest of ['v1.1.4', 'build-next']) {
    const stable = release(9, 'v1.1.4', ['MuseumMuse-unsigned.ipa'], {
      published_at: newest === 'v1.1.4' ? '2026-10-20T00:00:00Z' : '2026-10-19T00:00:00Z',
    });
    const build = release(10, 'build-next', ['MuseumMuse-unsigned.ipa'], {
      prerelease: true, published_at: newest === 'build-next' ? '2026-10-20T00:00:00Z' : '2026-10-19T00:00:00Z',
    });
    const source = listing([
      [release(24, 'other-v9', ['MuseumMuse-unsigned.ipa']),
        release(23, 'v9-draft', ['MuseumMuse-unsigned.ipa'], { draft: true }),
        release(22, 'v8', ['MuseumMuse-compatibility-unsigned.ipa']), stable],
      [build],
    ]);
    const config = subscription({ kind: 'github', repository: 'owner/repo', tagPrefix: 'build-|v', assetPattern: 'MuseumMuse-unsigned.ipa', includePrereleases: true });
    const candidates = await releaseCandidates(config, {}, source.cache, source.transport);
    assert.equal(chooseCandidate(candidates).tag, newest, 'neither tag family nor a higher release ID takes priority over publication time');
    assert.deepEqual(await releaseCandidates(config, {}, source.cache, source.transport), candidates);
    assert.equal(source.calls(), 2, 'cached listings retain the same selection');
    const stableOnly = await releaseCandidates({ ...config, includePrereleases: false }, {}, source.cache, source.transport);
    assert.equal(chooseCandidate(stableOnly).tag, 'v1.1.4', 'the prerelease setting remains effective');
  }
});
