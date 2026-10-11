import { SourceError } from './errors.mjs';
import { publicURL } from './urls.mjs';

// Existing URL subscriptions only check availability; never consume the IPA body.
export async function checkIPAExists(url, transport = fetch) {
  let target = publicURL(url);
  const request = async method => {
    for (let hop = 0; ; hop++) {
      const response = await transport(target, {
        method, headers: method === 'GET' ? { Range: 'bytes=0-0', 'Accept-Encoding': 'identity' } : {},
        redirect: 'manual', signal: AbortSignal.timeout(15000), cf: { cacheTtl: 0 },
      });
      await response.body?.cancel();
      if (![301, 302, 303, 307, 308].includes(response.status)) return response;
      const location = response.headers.get('location');
      if (!location || hop >= 5) throw new SourceError('BAD_REDIRECT', '下载重定向无效或次数过多');
      target = publicURL(new URL(location, target).href);
    }
  };
  let response = await request('HEAD');
  // Some file hosts only implement GET. Cancel even when they ignore Range.
  if ([405, 501].includes(response.status)) response = await request('GET');
  if (response.ok) return;
  if (response.status === 429 || response.status >= 500) {
    throw new SourceError('UPSTREAM_UNAVAILABLE', '下载服务器限流或暂时不可用', 422, true);
  }
  throw new SourceError('DOWNLOAD_INACCESSIBLE', `下载地址无法访问（HTTP ${response.status}）`);
}
