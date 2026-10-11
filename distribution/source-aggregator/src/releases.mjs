import { SourceError } from './errors.mjs';
import { glob, publicURL } from './urls.mjs';

export async function releaseCandidates(config, env, cache, transport = fetch) {
  // Cache a bounded complete release listing, shared by subscriptions to this repo.
  const cacheKey = `github:${config.repository.toLowerCase()}`;
  const previous = await cache.get(cacheKey);
  let releases;
  if (previous && Date.now() - previous.checkedAt < 60000) releases = previous.releases;
  else {
    const headers = { Accept: 'application/vnd.github+json', 'User-Agent': 'SignOs-Source/1', 'X-GitHub-Api-Version': '2022-11-28' };
    if (env.GITHUB_TOKEN) headers.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
    if (previous?.etag) headers['If-None-Match'] = previous.etag;
    let etag = null;
    releases = [];
    for (let page = 1; page <= 10; page++) {
      const response = await transport(`https://api.github.com/repos/${config.repository}/releases?per_page=100&page=${page}`, {
        headers: page === 1 ? headers : { ...headers, 'If-None-Match': '' }, signal: AbortSignal.timeout(15000),
      });
      if (page === 1 && response.status === 304 && previous) { releases = previous.releases; etag = previous.etag; break; }
      if (!response.ok) {
        await response.body?.cancel();
        const limited = response.status === 429 || (response.status === 403 && response.headers.get('x-ratelimit-remaining') === '0');
        throw new SourceError(limited ? 'GITHUB_RATE_LIMIT' : 'GITHUB_UNAVAILABLE', limited ? 'GitHub API 已限流，请稍后重试' : `无法读取 GitHub Release（HTTP ${response.status}）`, 422, limited || response.status >= 500);
      }
      // Release notes are capped before persistence; token and transient API headers never persist.
      const reader = response.body.getReader();
      const chunks = []; let count = 0;
      for (;;) {
        const { value, done } = await reader.read(); if (done) break;
        count += value.length;
        if (count > 4 * 1024 * 1024) { await reader.cancel(); throw new SourceError('RELEASE_RESPONSE_LIMIT', 'GitHub Release 响应超过处理限额'); }
        chunks.push(value);
      }
      const bytes = new Uint8Array(count); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      let raw;
      try { raw = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new SourceError('GITHUB_RESPONSE_INVALID', 'GitHub Release 返回内容无效'); }
      if (!Array.isArray(raw)) throw new SourceError('GITHUB_RESPONSE_INVALID', 'GitHub Release 返回内容无效');
      if (page === 1) etag = response.headers.get('etag');
      releases.push(...raw.filter(x => !x.draft).map(x => ({
        id: x.id, tag: x.tag_name, prerelease: x.prerelease, publishedAt: x.published_at,
        notes: String(x.body ?? '').slice(0, 2000),
        assets: (x.assets ?? []).filter(a => /\.ipa$/i.test(a.name)).map(a => ({
          id: a.id, name: a.name, size: a.size, url: a.browser_download_url, updatedAt: a.updated_at,
        })),
      })));
      if (JSON.stringify(releases).length > 1024 * 1024) throw new SourceError('RELEASE_SCAN_LIMIT', 'Release 列表超过处理限额，请缩小仓库范围');
      if (!response.headers.get('link')?.includes('rel="next"')) break;
      if (page === 10) throw new SourceError('RELEASE_SCAN_LIMIT', 'Release 列表超过扫描限额，请缩小仓库范围');
    }
    await cache.put(cacheKey, { etag, releases, checkedAt: Date.now() });
  }
  const eligible = releases.filter(x => (config.includePrereleases || !x.prerelease) && (!config.tagPrefix || x.tag.startsWith(config.tagPrefix)));
  eligible.sort((a, b) => Date.parse(b.publishedAt) - Date.parse(a.publishedAt) || b.id - a.id);
  if (!eligible.length) throw new SourceError('RELEASE_NOT_FOUND', '没有找到符合 tag 和预发布规则的 Release');
  // Android-only releases and unrelated IPA variants must not hide an older matching IPA.
  const release = eligible.find(x => x.assets.some(a => !config.assetPattern || glob(config.assetPattern, a.name)));
  if (!release) throw new SourceError('ASSET_NOT_FOUND', '符合 tag 和预发布规则的 Release 中没有符合匹配规则的 IPA 附件');
  const candidates = release.assets.filter(a => !config.assetPattern || glob(config.assetPattern, a.name)).map(a => ({
    ...a, url: publicURL(a.url), releaseId: release.id, tag: release.tag, publishedAt: release.publishedAt, notes: release.notes,
  }));
  return candidates;
}

export function chooseCandidate(candidates) {
  if (candidates.length !== 1) throw new SourceError('ASSET_AMBIGUOUS', '匹配到多个 IPA，请选择附件或调整匹配规则', 422, false, candidates);
  return candidates[0];
}
