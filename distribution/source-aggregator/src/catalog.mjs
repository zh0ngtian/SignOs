import { DurableObject } from 'cloudflare:workers';
import { parseIPA } from './ipa.mjs';
import { SourceError, errorData, json } from './errors.mjs';
import { subscription, publicURL } from './urls.mjs';
import { releaseCandidates, chooseCandidate } from './releases.mjs';

const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).filter(k => value[k] !== undefined).sort().map(k => [k, canonical(value[k])])) : value;
const now = () => new Date().toISOString();
const HISTORY_LIMIT = 20;
const terminal = new Set(['succeeded', 'failed', 'superseded']);
const tokenHash = async token => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token)))].map(x => x.toString(16).padStart(2, '0')).join('');

export class Catalog extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
    this.env = env;
    ctx.blockConcurrencyWhile(async () => {
      this.data = await ctx.storage.get('catalog') ?? {
        schemaVersion: 1, revision: 0,
        settings: { id: env.SOURCE_ID || 'yao', identifier: env.SOURCE_IDENTIFIER || 'tech.zh0ngtian.yao-app-source', name: env.SOURCE_NAME || 'Yao App Source', description: '聚合 GitHub Release 和原始 IPA 地址的软件源' },
        entries: [], jobs: [],
      };
    });
  }

  async save() {
    const active = this.data.jobs.filter(j => !terminal.has(j.status));
    const recent = this.data.jobs.filter(j => terminal.has(j.status) && Date.now() - Date.parse(j.finishedAt) < 7 * 86400000).slice(-100);
    this.data.jobs = [...recent, ...active];
    await this.ctx.storage.put('catalog', this.data);
  }

  entry(id) {
    const entry = this.data.entries.find(x => x.id === id);
    if (!entry) throw new SourceError('ENTRY_NOT_FOUND', '订阅不存在', 404);
    return entry;
  }

  checkRevision(body) {
    if (body.revision !== this.data.revision) throw new SourceError('REVISION_CONFLICT', '软件源已被其他设备修改，请刷新后重试', 409);
  }

  async authorized(request) {
    const token = request.headers.get('Authorization')?.match(/^Bearer (.+)$/)?.[1] ?? '';
    const expected = this.data.tokenHash ?? (this.env.ADMIN_TOKEN ? await tokenHash(this.env.ADMIN_TOKEN) : null);
    if (!expected || token.length < 20 || token.length > 512) return false;
    const actual = await tokenHash(token);
    let diff = 0;
    for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ actual.charCodeAt(i);
    return diff === 0;
  }

  async body(request) {
    if (!request.headers.get('Content-Type')?.startsWith('application/json')) throw new SourceError('INVALID_BODY', '请求必须使用 JSON', 400);
    const reader = request.body?.getReader();
    if (!reader) throw new SourceError('INVALID_BODY', '缺少请求内容', 400);
    const chunks = []; let length = 0;
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > 1024 * 1024) { await reader.cancel(); throw new SourceError('BODY_LIMIT', '配置超过大小限制', 413); }
      chunks.push(value);
    }
    const data = new Uint8Array(length); let offset = 0;
    for (const c of chunks) { data.set(c, offset); offset += c.length; }
    let result;
    try { result = JSON.parse(new TextDecoder().decode(data)); } catch { throw new SourceError('INVALID_BODY', 'JSON 格式无效', 400); }
    if (!result || typeof result !== 'object' || Array.isArray(result)) throw new SourceError('INVALID_BODY', '请求内容无效', 400);
    return result;
  }

  async schedule(entry) {
    if (entry.config.paused) return;
    if (this.data.jobs.some(j => j.entryId === entry.id && j.entryRevision === entry.revision && !terminal.has(j.status))) return;
    const job = { id: crypto.randomUUID(), entryId: entry.id, entryRevision: entry.revision, status: 'queued', attempts: 0, createdAt: now(), nextAt: Date.now() + 50 };
    this.data.jobs.push(job);
    entry.status = 'queued'; entry.error = null;
    await this.save();
    const alarm = await this.ctx.storage.getAlarm();
    if (!alarm || alarm > job.nextAt) await this.ctx.storage.setAlarm(job.nextAt);
  }

  async tick() {
    for (const entry of this.data.entries) await this.schedule(entry);
  }

  publicDocument(origin) {
    const settings = this.data.settings;
    return {
      name: settings.name, identifier: settings.identifier, description: settings.description,
      subtitle: 'GitHub Release 与 IPA 聚合', sourceURL: `${origin}/sources/${settings.id}.json`,
      iconURL: `${origin}/icon.png`, sourceicon: `${origin}/icon.png`, news: [],
      apps: this.data.entries.filter(e => e.published && e.current).map(entry => {
        const current = entry.current;
        const version = v => ({ version: v.metadata.version, ...(v.metadata.buildVersion ? { buildVersion: v.metadata.buildVersion } : {}),
          date: v.date, localizedDescription: v.notes || '', downloadURL: v.downloadURL, size: v.inspection.fullBytes,
          ...(v.metadata.minOSVersion ? { minOSVersion: v.metadata.minOSVersion } : {}), ...(v.sha256 ? { sha256: v.sha256 } : {}) });
        return {
          name: current.metadata.name, bundleIdentifier: current.metadata.bundleIdentifier,
          // Independent subscription identity preserves variants with the same Bundle ID.
          appID: entry.id, legacyDefault: entry.presentation?.legacyDefault === true, developerName: entry.presentation?.developerName || (entry.config.kind === 'github' ? entry.config.repository.split('/')[0] : '原始 IPA 发布者'),
          localizedDescription: entry.presentation?.description || '', iconURL: entry.presentation?.iconURL || current.iconURL || `${origin}/icon.png`,
          ...version(current), versionDate: current.date, versionDescription: current.notes || '',
          versions: [current, ...entry.history].slice(0, HISTORY_LIMIT + 1).map(version),
        };
      }),
    };
  }

  async fetch(request) {
    try {
      const url = new URL(request.url), path = url.pathname, method = request.method;
      if (['/source.json', '/appstore', `/sources/${this.data.settings.id}.json`].includes(path) && ['GET', 'HEAD'].includes(method)) {
        const document = this.publicDocument(url.origin);
        const raw = JSON.stringify(document), etag = `"${await tokenHash(raw)}"`;
        const headers = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'public, max-age=60', ETag: etag, 'X-Content-Type-Options': 'nosniff' };
        if (request.headers.get('If-None-Match')?.split(',').some(x => x.trim() === etag || x.trim() === '*')) return new Response(null, { status: 304, headers });
        return new Response(method === 'HEAD' ? null : raw, { headers });
      }
      if (!path.startsWith('/api/')) return json({ error: { code: 'NOT_FOUND', message: '接口不存在' } }, 404);
      if (!await this.authorized(request)) return json({ error: { code: 'UNAUTHORIZED', message: '管理 Token 无效或已撤销' } }, 401);
      if (method === 'GET' && path === '/api/catalog') return json({ revision: this.data.revision, settings: this.data.settings, entries: this.data.entries, jobs: this.data.jobs });
      if (method === 'GET' && path === '/api/export') {
        // Metadata is included as evidence, but restore reparses it before publication.
        this.data.backupKey ??= crypto.randomUUID() + crypto.randomUUID();
        await this.save();
        const backup = { schemaVersion: 1, settings: this.data.settings, entries: this.data.entries.map(e => ({ id: e.id, config: e.config, current: e.current, history: e.history, presentation: e.presentation, published: e.published })), exportedAt: now() };
        return json({ ...backup, signature: await this.backupSignature(backup) });
      }
      const match = /^\/api\/entries\/([a-f0-9-]+)(?:\/(confirm|sync|history|presentation|attest))?$/.exec(path);
      if (method === 'DELETE' && match && !match[2]) {
        const body = await this.body(request); this.checkRevision(body); this.entry(match[1]);
        this.data.entries = this.data.entries.filter(e => e.id !== match[1]); this.data.revision++;
        await this.save(); return json({ revision: this.data.revision });
      }
      if (!['POST', 'PATCH'].includes(method)) return json({ error: { code: 'METHOD_NOT_ALLOWED', message: '请求方法不支持' } }, 405);
      const body = await this.body(request);
      if (path === '/api/discover' && method === 'POST') {
        const config = subscription(body.config);
        if (config.kind !== 'github') throw new SourceError('INVALID_KIND', '只有 GitHub 订阅需要选择附件');
        const candidates = await releaseCandidates(config, this.env, this.ctx.storage);
        return json({ candidates });
      }
      if (path === '/api/entries' && method === 'POST') {
        this.checkRevision(body);
        if (this.data.entries.length >= 200) throw new SourceError('ENTRY_LIMIT', '软件源最多支持 200 个订阅');
        if (body.metadata || body.current) throw new SourceError('MANUAL_METADATA_DISABLED', '应用元信息只能自动解析');
        const entry = { id: crypto.randomUUID(), revision: 1, config: subscription(body.config), published: false, current: null, history: [], status: 'pending', error: null, createdAt: now() };
        this.data.entries.push(entry); this.data.revision++; await this.save(); await this.schedule(entry);
        return json({ entry, revision: this.data.revision }, 201);
      }
      if (match) {
        const entry = this.entry(match[1]);
        if (match[2] === 'sync' && method === 'POST') { if (entry.config.kind === 'github') await this.ctx.storage.delete(`github:${entry.config.repository.toLowerCase()}`); await this.schedule(entry); return json({ entry, revision: this.data.revision }, 202); }
        this.checkRevision(body);
        if (match[2] === 'presentation' && method === 'POST') {
          if (typeof body.developerName !== 'string' || body.developerName.length > 200 || typeof body.description !== 'string' || body.description.length > 4000) throw new SourceError('INVALID_SETTINGS', '展示信息无效');
          entry.presentation = { developerName: body.developerName, description: body.description, iconURL: publicURL(body.iconURL), legacyDefault: body.legacyDefault === true };
          this.data.revision++; await this.save(); return json({ revision: this.data.revision });
        }
        if (match[2] === 'attest' && method === 'POST') {
          if (!entry.current) throw new SourceError('NOT_READY', '尚未成功解析');
          const digest = await this.githubDigest(entry.current.downloadURL, body.sha256, entry.current.inspection.fullBytes);
          entry.current.sha256 = digest;
          this.data.revision++; await this.save(); return json({ revision: this.data.revision, sha256: digest });
        }
        if (match[2] === 'history' && method === 'POST') {
          if (!entry.current || !Array.isArray(body.versions) || body.versions.length > HISTORY_LIMIT) throw new SourceError('INVALID_HISTORY', '历史版本列表无效或尚未解析当前应用');
          for (const version of body.versions) {
            const downloadURL = publicURL(version.downloadURL);
            if (!Number.isFinite(Date.parse(version.date)) || typeof version.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(version.sha256)) throw new SourceError('INVALID_HISTORY', '历史地址、日期或 SHA-256 无效');
            if ([entry.current, ...entry.history].some(v => v.downloadURL === downloadURL) || this.data.jobs.some(j => j.entryId === entry.id && j.version?.downloadURL === downloadURL && !terminal.has(j.status))) continue;
            this.data.jobs.push({ id: crypto.randomUUID(), entryId: entry.id, entryRevision: entry.revision, kind: 'history', version: { downloadURL, date: version.date, sha256: version.sha256 }, status: 'queued', attempts: 0, createdAt: now(), nextAt: Date.now() + 50 });
          }
          await this.save(); await this.nextAlarm(); return json({ accepted: true }, 202);
        }
        if (match[2] === 'confirm' && method === 'POST') {
          if (!entry.current || entry.status !== 'ready') throw new SourceError('NOT_READY', '自动解析尚未成功，无法添加到公开软件源');
          entry.published = true; entry.status = 'succeeded'; this.data.revision++; await this.save();
          return json({ entry, revision: this.data.revision });
        }
        if (!match[2] && method === 'PATCH') {
          if (body.metadata || body.current) throw new SourceError('MANUAL_METADATA_DISABLED', '应用元信息只能自动解析');
          entry.config = subscription(body.config); entry.revision++; entry.status = 'pending'; entry.error = null;
          this.data.revision++; await this.save(); await this.schedule(entry);
          return json({ entry, revision: this.data.revision });
        }
      }
      if (path === '/api/sync' && method === 'POST') { await this.tick(); return json({ accepted: true }, 202); }
      if (path === '/api/settings' && method === 'PATCH') {
        this.checkRevision(body);
        if (typeof body.name !== 'string' || !body.name.trim() || body.name.length > 100 || typeof body.description !== 'string' || body.description.length > 2000) throw new SourceError('INVALID_SETTINGS', '软件源名称或简介无效');
        Object.assign(this.data.settings, { name: body.name.trim(), description: body.description }); this.data.revision++;
        await this.save(); return json({ revision: this.data.revision, settings: this.data.settings });
      }
      if (path === '/api/token' && method === 'POST') {
        if (typeof body.token !== 'string' || body.token.length < 32 || body.token.length > 512) throw new SourceError('INVALID_TOKEN', '新 Token 长度需要为 32 至 512 字符');
        this.data.tokenHash = await tokenHash(body.token); await this.save(); return json({ rotated: true });
      }
      if (path === '/api/restore' && method === 'POST') {
        this.checkRevision(body);
        const backup = body.backup;
        if (backup?.schemaVersion !== 1 || backup.settings?.id !== this.data.settings.id || backup.settings?.identifier !== this.data.settings.identifier || !Array.isArray(backup.entries) || backup.entries.length > 200) throw new SourceError('INVALID_BACKUP', '配置备份格式或软件源身份不匹配');
        const { signature, ...payload } = backup;
        const trusted = this.data.backupKey && signature === await this.backupSignature(payload);
        if (signature && this.data.backupKey && !trusted) throw new SourceError('INVALID_BACKUP', '备份校验失败，文件可能已修改');
        const ids = new Set();
        const entries = backup.entries.map(e => {
          if (!/^[a-f0-9-]{36}$/.test(e.id) || ids.has(e.id)) throw new SourceError('INVALID_BACKUP', '备份包含重复或无效的订阅 ID');
          ids.add(e.id);
          // Never trust edited backup metadata or URLs as a way to bypass the parser.
          const existing = this.data.entries.find(x => x.id === e.id);
          return { id: e.id, revision: (existing?.revision ?? 0) + 1, config: subscription(e.config), published: trusted ? !!e.published : existing?.published ?? false, current: trusted ? e.current : existing?.current ?? null, history: trusted ? e.history : existing?.history ?? [], presentation: trusted ? e.presentation : existing?.presentation, status: 'pending', error: null, createdAt: existing?.createdAt ?? now() };
        });
        this.data.entries = entries; this.data.revision++; await this.save(); await this.tick();
        return json({ revision: this.data.revision, restored: entries.length });
      }
      return json({ error: { code: 'NOT_FOUND', message: '接口不存在' } }, 404);
    } catch (error) { return json({ error: errorData(error) }, error.status || 422); }
  }

  async alarm() {
    const job = this.data.jobs.find(j => !terminal.has(j.status) && j.nextAt <= Date.now());
    if (!job) { await this.nextAlarm(); return; }
    const entry = this.data.entries.find(e => e.id === job.entryId);
    if (!entry || entry.revision !== job.entryRevision || entry.config.paused) {
      Object.assign(job, { status: 'superseded', finishedAt: now() }); await this.save(); await this.nextAlarm(); return;
    }
    job.status = 'running'; job.attempts++; job.nextAt = Date.now() + 300000;
    entry.status = 'parsing'; await this.save();
    await this.ctx.storage.setAlarm(job.nextAt);
    try {
      if (job.kind === 'history') {
        const inspection = await parseIPA(job.version.downloadURL);
        const sha256 = await this.githubDigest(job.version.downloadURL, job.version.sha256, inspection.fullBytes);
        const live = this.data.entries.find(e => e.id === job.entryId);
        if (!live || live.revision !== job.entryRevision) Object.assign(job, { status: 'superseded', finishedAt: now() });
        else {
          if (inspection.metadata.bundleIdentifier !== live.current?.metadata.bundleIdentifier) throw new SourceError('BUNDLE_ID_CHANGED', '历史 IPA 的 Bundle ID 与应用不符');
          if (!live.history.some(v => v.downloadURL === job.version.downloadURL)) live.history.push({ metadata: inspection.metadata, inspection, downloadURL: job.version.downloadURL, date: job.version.date, sha256, inspectedAt: now(), notes: '' });
          live.history.sort((a, b) => Date.parse(b.date) - Date.parse(a.date));
          live.history = live.history.slice(0, HISTORY_LIMIT);
          Object.assign(job, { status: 'succeeded', finishedAt: now() }); this.data.revision++;
          live.status = live.published ? 'succeeded' : 'ready';
        }
        await this.save(); await this.nextAlarm(); return;
      }
      const config = structuredClone(entry.config);
      const candidate = config.kind === 'github' ? chooseCandidate(await releaseCandidates(config, this.env, this.ctx.storage)) : { url: config.url, notes: '', publishedAt: null };
      const fingerprint = config.kind === 'github' ? `${candidate.releaseId}:${candidate.id}:${candidate.updatedAt}:${candidate.size}` : null;
      let inspection;
      if (entry.current?.fingerprint === fingerprint && fingerprint && entry.current.downloadURL === candidate.url) inspection = entry.current.inspection;
      else inspection = await parseIPA(candidate.url);
      // Network awaits can interleave with edits or deletion. Publish only to the same revision.
      const live = this.data.entries.find(e => e.id === job.entryId);
      if (!live || live.revision !== job.entryRevision || live.config.paused) {
        Object.assign(job, { status: 'superseded', finishedAt: now() });
      } else {
        if (live.current && inspection.metadata.bundleIdentifier !== live.current.metadata.bundleIdentifier) throw new SourceError('BUNDLE_ID_CHANGED', '新 IPA 的 Bundle ID 与原应用不符，已保留原版本');
        const current = { metadata: inspection.metadata, inspection, downloadURL: candidate.url, date: candidate.publishedAt || now(), notes: candidate.notes, tag: candidate.tag || null, assetName: candidate.name || null, fingerprint, inspectedAt: now() };
        const same = live.current && live.current.downloadURL === current.downloadURL && live.current.inspection.strongETag === inspection.strongETag && JSON.stringify(live.current.metadata) === JSON.stringify(current.metadata);
        if (!same) {
          if (live.current) live.history = [live.current, ...live.history].slice(0, HISTORY_LIMIT);
          live.current = current;
        }
        live.lastSuccessAt = now(); live.error = null; live.status = live.published ? 'succeeded' : 'ready';
        Object.assign(job, { status: 'succeeded', finishedAt: now() });
        this.data.revision++;
      }
    } catch (error) {
      const live = this.data.entries.find(e => e.id === job.entryId);
      if (live && live.revision === job.entryRevision) {
        const reason = errorData(error); live.error = reason;
        if (reason.retryable && job.attempts < 3) {
          job.status = 'queued'; job.nextAt = Date.now() + Math.min(60000 * 2 ** (job.attempts - 1), 300000); live.status = 'retrying';
        } else { job.status = 'failed'; job.finishedAt = now(); live.status = 'failed'; }
        this.data.revision++;
      } else Object.assign(job, { status: 'superseded', finishedAt: now() });
    }
    await this.save(); await this.nextAlarm();
  }

  async backupSignature(payload) {
    const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(this.data.backupKey), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    return [...new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(JSON.stringify(canonical(payload)))))].map(x => x.toString(16).padStart(2, '0')).join('');
  }

  async githubDigest(downloadURL, expected, size) {
    const url = new URL(publicURL(downloadURL));
    const match = /^\/([^/]+)\/([^/]+)\/releases\/download\/(.+)\/([^/]+)$/.exec(url.pathname);
    if (url.hostname !== 'github.com' || !match || !/^[a-f0-9]{64}$/.test(expected ?? '')) throw new SourceError('DIGEST_UNVERIFIED', '完整 SHA-256 需要 GitHub Release 的附件散列证明');
    const headers = { Accept: 'application/vnd.github+json', 'User-Agent': 'SignOs-Source/1' };
    if (this.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${this.env.GITHUB_TOKEN}`;
    const response = await fetch(`https://api.github.com/repos/${match[1]}/${match[2]}/releases/tags/${encodeURIComponent(decodeURIComponent(match[3]))}`, { headers, signal: AbortSignal.timeout(15000) });
    if (!response.ok) { await response.body?.cancel(); throw new SourceError('DIGEST_UNVERIFIED', `GitHub 附件证明读取失败（HTTP ${response.status}）`, 422, response.status >= 500 || response.status === 429); }
    const release = await response.json();
    const asset = release.assets?.find(a => a.browser_download_url === downloadURL);
    if (asset?.digest !== `sha256:${expected}` || asset?.size !== size) throw new SourceError('DIGEST_MISMATCH', 'GitHub 附件大小或完整 SHA-256 与发布凭证不一致');
    return expected;
  }

  async nextAlarm() {
    const pending = this.data.jobs.filter(j => !terminal.has(j.status));
    if (pending.length) await this.ctx.storage.setAlarm(Math.max(Date.now() + 50, Math.min(...pending.map(j => j.nextAt))));
    else await this.ctx.storage.deleteAlarm();
  }
}
