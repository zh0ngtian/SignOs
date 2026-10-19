import { SourceError } from './errors.mjs';

export function publicURL(value) {
  let url;
  try { url = new URL(value); } catch { throw new SourceError('INVALID_URL', '请填写有效的 HTTPS 下载地址'); }
  const host = url.hostname.toLowerCase();
  if (url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443') ||
      !host.includes('.') || host.startsWith('[') || /^\d+\.\d+\.\d+\.\d+$/.test(host) ||
      host === 'localhost' || /\.(localhost|local|internal|lan)$/.test(host)) {
    throw new SourceError('INVALID_URL', '下载地址必须是可公开访问的 HTTPS 地址');
  }
  url.hash = '';
  return url.href;
}

export function repository(value) {
  const raw = String(value ?? '').trim().replace(/^https:\/\/github\.com\//i, '').replace(/\/?$/, '').replace(/\.git$/, '');
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(raw)) throw new SourceError('INVALID_REPOSITORY', '请填写 GitHub 仓库地址或 owner/repo');
  return raw;
}

export function glob(pattern, name) {
  const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
  return new RegExp(`^${escaped}$`, 'i').test(name);
}

export function tagPrefixes(value) {
  const rule = String(value ?? '').trim();
  if (!rule) return [];
  const prefixes = rule.split('|').map(prefix => prefix.trim());
  if (rule.length > 100 || prefixes.some(prefix => !prefix)) {
    throw new SourceError('INVALID_RULE', 'tag 前缀最多 100 字符，多个前缀用 | 分隔且不能为空');
  }
  return prefixes;
}

export function subscription(input) {
  if (!['github', 'url'].includes(input.kind)) throw new SourceError('INVALID_KIND', '请选择 GitHub Release 或直接 IPA 地址');
  const out = { kind: input.kind, paused: input.paused === true };
  if (input.kind === 'github') {
    out.repository = repository(input.repository);
    out.tagPrefix = tagPrefixes(input.tagPrefix).join('|');
    out.assetPattern = String(input.assetPattern ?? '').trim();
    out.includePrereleases = input.includePrereleases === true;
    if (out.tagPrefix.length > 100 || out.assetPattern.length > 200 || out.assetPattern.includes('/') || out.assetPattern.includes('\\')) {
      throw new SourceError('INVALID_RULE', 'tag 前缀或附件匹配规则无效');
    }
  } else out.url = publicURL(input.url);
  return out;
}
