export const KEEP_VERSIONS = 10;
export const GRACE_MS = 7 * 24 * 60 * 60 * 1000;
export const BUDGET_BYTES = 8_000_000_000;
export const LOCK_KEY = '_maintenance/lock.json';
export const STATE_KEY = '_maintenance/gc.json';
const FILE = /^files\/[A-Za-z0-9._-]+\.(ipa|png)$/;

export function trimVersions(source) {
  const result = structuredClone(source);
  if (!Array.isArray(result.apps) || !result.apps.length) throw new Error('Missing apps; cleanup stopped');
  for (const app of result.apps) {
    if (!app.downloadURL || !Array.isArray(app.versions) || !app.versions.length) {
      throw new Error('Missing current release/history; cleanup stopped');
    }
    const current = app.versions.find(v => v.downloadURL === app.downloadURL);
    if (!current) throw new Error('Current release absent from history; cleanup stopped');
    // Keep the active release even after a deliberate rollback. Dates describe publication order.
    const others = app.versions.filter(v => v !== current).map((v, i) => {
      const date = Date.parse(v.date);
      if (!Number.isFinite(date)) throw new Error('Invalid release date; cleanup stopped');
      return { v, i, date };
    }).sort((a, b) => b.date - a.date || a.i - b.i);
    app.versions = [current, ...others.map(item => item.v)].slice(0, KEEP_VERSIONS);
  }
  return result;
}

export function references(source) {
  const sourceURL = new URL(source.sourceURL);
  if (sourceURL.protocol !== 'https:' || sourceURL.pathname !== '/source.json' ||
      sourceURL.search || sourceURL.hash || sourceURL.username || sourceURL.password) throw new Error('Invalid source URL');
  const base = source.sourceURL.slice(0, -'/source.json'.length);
  const keys = new Set();
  function collect(value) {
    if (typeof value === 'string' && value.startsWith(base + '/files/')) {
      const key = value.slice(base.length + 1);
      if (!FILE.test(key)) throw new Error('Invalid resource URL');
      keys.add(key);
    } else if (Array.isArray(value)) value.forEach(collect);
    else if (value && typeof value === 'object') Object.values(value).forEach(collect);
  }
  collect(source);
  for (const app of source.apps) {
    for (const release of [app, ...app.versions]) {
      if (typeof release.downloadURL !== 'string' || !release.downloadURL.startsWith(base + '/files/') ||
          !FILE.test(release.downloadURL.slice(base.length + 1))) throw new Error('Invalid release URL');
    }
  }
  return keys;
}

export async function listObjects(bucket) {
  const objects = [];
  let cursor;
  do {
    const page = await bucket.list({ limit: 1000, ...(cursor ? { cursor } : {}) });
    objects.push(...page.objects);
    if (page.truncated && (!page.cursor || page.cursor === cursor)) throw new Error('Incomplete R2 listing');
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return objects;
}

export async function cleanup(bucket, now = Date.now()) {
  const owner = crypto.randomUUID();
  const lock = await bucket.put(LOCK_KEY, JSON.stringify({ owner, kind: 'cleanup', startedAt: now }),
    { onlyIf: new Headers({ 'If-None-Match': '*' }) });
  if (!lock) return { status: 'busy', deleted: 0 };
  try {
    const manifest = await bucket.get('source.json');
    if (!manifest) throw new Error('Missing source.json; cleanup stopped');
    const original = await manifest.text();
    const source = JSON.parse(original);
    const retained = trimVersions(source);
    const used = references(retained);
    const objects = await listObjects(bucket);
    const inventory = new Map(objects.map(o => [o.key, o]));
    for (const key of used) if (!inventory.has(key)) throw new Error(`Missing referenced object: ${key}`);
    const stateObject = await bucket.get(STATE_KEY);
    const state = stateObject ? await stateObject.json() : { version: 1, pending: {} };
    if (state.version !== 1 || !state.pending || typeof state.pending !== 'object' || Array.isArray(state.pending)) {
      throw new Error('Invalid GC state; cleanup stopped');
    }
    let manifestEtag = manifest.etag;
    const changed = JSON.stringify(source) !== JSON.stringify(retained);
    if (changed) {
      await bucket.put(`_maintenance/manifests/${manifest.etag}.json`, original);
      const updated = await bucket.put('source.json', JSON.stringify(retained, null, 2) + '\n',
        { onlyIf: { etagMatches: manifest.etag }, httpMetadata: { contentType: 'application/json' } });
      if (!updated) throw new Error('Manifest changed; cleanup stopped');
      manifestEtag = updated.etag;
    }
    const deletions = [];
    for (const key of Object.keys(state.pending)) {
      if (used.has(key) || !inventory.has(key) || !FILE.test(key)) delete state.pending[key];
    }
    for (const object of objects) {
      if (!FILE.test(object.key) || used.has(object.key)) continue;
      const uploaded = object.uploaded.toISOString();
      const previous = state.pending[object.key];
      if (!previous || previous.etag !== object.etag || previous.uploaded !== uploaded ||
          !Number.isFinite(previous.since) || previous.since > now) {
        state.pending[object.key] = { since: now, etag: object.etag, uploaded };
      } else if (now - previous.since >= GRACE_MS) deletions.push(object.key);
    }
    // Persist the grace-period clock before deleting anything; never infer age from upload time.
    await bucket.put(STATE_KEY, JSON.stringify(state));
    const latest = await bucket.head('source.json');
    if (latest?.etag !== manifestEtag) throw new Error('Manifest changed; deletion stopped');
    for (let i = 0; i < deletions.length; i += 1000) await bucket.delete(deletions.slice(i, i + 1000));
    for (const key of deletions) delete state.pending[key];
    await bucket.put(STATE_KEY, JSON.stringify(state));
    const bytes = objects.reduce((total, o) => total + (deletions.includes(o.key) ? 0 : o.size), 0);
    const report = { status: 'ok', at: new Date(now).toISOString(), trimmed: changed,
      deleted: deletions.length, pending: Object.keys(state.pending).length, bytes,
      budgetBytes: BUDGET_BYTES, overBudget: bytes > BUDGET_BYTES };
    await bucket.put('_maintenance/last-run.json', JSON.stringify(report));
    return report;
  } finally {
    // Locks intentionally do not expire: an interrupted job fails closed until operator recovery.
    const current = await bucket.get(LOCK_KEY);
    if (current && (await current.json()).owner === owner) await bucket.delete(LOCK_KEY);
  }
}
