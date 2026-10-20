import { SourceError } from './errors.mjs';
import { publicURL, repository } from './urls.mjs';

export function githubHeaders(env, accept = 'application/vnd.github+json') {
  return { Accept: accept, 'User-Agent': 'SignOs-Source/1', 'X-GitHub-Api-Version': '2022-11-28',
    ...(env.GITHUB_TOKEN ? { Authorization: `Bearer ${env.GITHUB_TOKEN}` } : {}) };
}

export async function githubJSON(path, env, transport = fetch) {
  const response = await transport(`https://api.github.com/${path}`, {
    headers: githubHeaders(env), redirect: 'manual', signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) {
    await response.body?.cancel();
    const limited = response.status === 429 || (response.status === 403 && response.headers.get('x-ratelimit-remaining') === '0');
    throw new SourceError(limited ? 'GITHUB_RATE_LIMIT' : 'GITHUB_UNAVAILABLE',
      limited ? 'GitHub API 已限流，请稍后重试' : `无法读取 GitHub 信息（HTTP ${response.status}）`, 422, limited || response.status >= 500);
  }
  return response.json();
}

export async function privateRepository(repo, env, transport = fetch) {
  if (!env.GITHUB_TOKEN) return false; // An anonymously readable release belongs to a public repository.
  const info = await githubJSON(`repos/${repository(repo)}`, env, transport);
  if (typeof info.private !== 'boolean') throw new SourceError('GITHUB_RESPONSE_INVALID', 'GitHub 仓库权限信息无效');
  return info.private;
}

function validateAsset(asset) {
  const repo = repository(asset?.repository);
  if (!Number.isSafeInteger(asset?.id) || asset.id <= 0 || typeof asset.name !== 'string' ||
      !/\.ipa$/i.test(asset.name) || /[/\\\x00-\x1f\x7f]/.test(asset.name) || asset.name.length > 255 ||
      !Number.isSafeInteger(asset.size) || asset.size <= 0) {
    throw new SourceError('INVALID_GITHUB_ASSET', '私有 IPA 附件记录无效');
  }
  return `https://api.github.com/repos/${repo}/releases/assets/${asset.id}`;
}

export function privateDownloadPath(entryID, asset) {
  validateAsset(asset);
  return `/downloads/${entryID}/${asset.id}/${encodeURIComponent(asset.name)}`;
}

// Resolve the signed CDN address only in memory for this transfer/inspection.
// Neither the caller's source Token nor the GitHub Token reaches the CDN.
export function privateAssetTransport(asset, env, transport = fetch) {
  const api = validateAsset(asset);
  let resolved;
  const load = async (_input, init = {}) => {
    if (!env.GITHUB_TOKEN) throw new SourceError('GITHUB_TOKEN_REQUIRED', '私有仓库需要服务端 GitHub 读取权限');
    const headers = new Headers({ 'Accept-Encoding': 'identity' });
    const inputHeaders = new Headers(init.headers);
    for (const key of ['Range', 'If-Range', 'If-None-Match', 'If-Modified-Since']) {
      if (inputHeaders.has(key)) headers.set(key, inputHeaders.get(key));
    }
    // GitHub's CDN can reject suffix ranges with 501. The asset API supplies
    // the immutable size, so express the same bytes as an explicit interval.
    const suffix = /^bytes=-(\d+)$/.exec(headers.get('Range') || '');
    if (suffix) {
      const count = Number(suffix[1]);
      if (!Number.isSafeInteger(count) || count < 1) throw new SourceError('INVALID_RANGE', '文件区段无效', 416);
      headers.set('Range', `bytes=${Math.max(0, asset.size - count)}-${asset.size - 1}`);
    }
    let target = resolved || api;
    for (let hop = 0; hop <= 5; hop++) {
      const isAPI = target === api;
      const outgoing = new Headers(headers);
      if (isAPI) for (const [key, value] of Object.entries(githubHeaders(env, 'application/octet-stream'))) outgoing.set(key, value);
      const response = await transport(target, { method: isAPI ? 'GET' : (init.method || 'GET'), headers: outgoing,
        redirect: 'manual', signal: init.signal || AbortSignal.timeout(15000), cf: { cacheTtl: 0 } });
      if (![301, 302, 303, 307, 308].includes(response.status)) {
        load.finalHost = new URL(target).hostname;
        if (!isAPI) resolved = target;
        return response;
      }
      const location = response.headers.get('location');
      await response.body?.cancel();
      if (!location || hop === 5) throw new SourceError('BAD_REDIRECT', 'GitHub 附件重定向无效');
      const next = new URL(publicURL(new URL(location, target).href));
      if (!['release-assets.githubusercontent.com', 'objects.githubusercontent.com', 'github-releases.githubusercontent.com'].includes(next.hostname)) {
        throw new SourceError('BAD_REDIRECT', 'GitHub 附件未指向受支持的下载服务器');
      }
      target = next.href;
    }
  };
  return load;
}

export async function privateAssetForURL(downloadURL, env, transport = fetch) {
  const url = new URL(publicURL(downloadURL));
  const match = /^\/([^/]+)\/([^/]+)\/releases\/download\/(.+)\/([^/]+)$/.exec(url.pathname);
  if (url.hostname !== 'github.com' || !match) return null;
  const repo = repository(`${match[1]}/${match[2]}`);
  if (!await privateRepository(repo, env, transport)) return null;
  const release = await githubJSON(`repos/${repo}/releases/tags/${encodeURIComponent(decodeURIComponent(match[3]))}`, env, transport);
  const asset = release.assets?.find(a => a.browser_download_url === downloadURL);
  if (!asset) throw new SourceError('ASSET_NOT_FOUND', '私有 Release 中找不到此 IPA 附件');
  const result = { repository: repo, id: asset.id, name: asset.name, size: asset.size };
  validateAsset(result);
  return result;
}

export async function downloadPrivateAsset(request, asset, env, transport = fetch) {
  const range = request.headers.get('Range');
  if (range && (range.length > 128 || !/^bytes=(?:\d+-\d*|-\d+)$/.test(range))) throw new SourceError('INVALID_RANGE', '只支持单个文件区段', 416);
  // Bound header/redirect latency without aborting a large IPA after 15 seconds.
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  let response;
  try {
    response = await privateAssetTransport(asset, env, transport)(null, {
      method: request.method, headers: request.headers, signal: controller.signal,
    });
  } finally { clearTimeout(timeout); }
  if (![200, 206, 304, 416].includes(response.status)) {
    await response.body?.cancel();
    throw new SourceError('DOWNLOAD_INACCESSIBLE', `私有附件无法访问（HTTP ${response.status}）`, 502, response.status === 429 || response.status >= 500);
  }
  const headers = new Headers({ 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
    'Content-Type': 'application/octet-stream', 'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(asset.name).replace(/['()*]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase())}` });
  for (const key of ['Content-Length', 'Content-Range', 'Accept-Ranges', 'ETag', 'Last-Modified']) {
    if (response.headers.has(key)) headers.set(key, response.headers.get(key));
  }
  const noBody = request.method === 'HEAD' || response.status === 304 || response.status === 416;
  if (noBody) await response.body?.cancel();
  // CDN error pages may echo their signed address. Only publish the range
  // status/headers, never the upstream error body.
  if (response.status === 416) headers.delete('Content-Length');
  return new Response(noBody ? null : response.body, { status: response.status, headers });
}
