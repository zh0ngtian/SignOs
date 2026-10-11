import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import fixtures from './png-fixtures.mjs';
import { normalizeIconPNG } from '../src/png.mjs';

test('Workers decodes split PNG/CgBI streams and rejects excess inflated pixels', async () => {
  const bundle = await build({
    stdin: {
      contents: `import { normalizeIconPNG } from './src/png.mjs';
        export default { async fetch(request) {
          try {
            const icon = normalizeIconPNG(new Uint8Array(await request.arrayBuffer()));
            return new Response(icon.png);
          } catch (error) { return new Response(error.message, { status: 422 }); }
        } };`,
      resolveDir: new URL('..', import.meta.url).pathname,
    },
    bundle: true, write: false, format: 'esm', platform: 'node',
  });
  const mf = new Miniflare(convertV4MiniflareOptions({
    modules: true, script: bundle.outputFiles[0].text,
    compatibilityDate: '2026-05-22', compatibilityFlags: ['nodejs_compat'],
  }));
  try {
    for (const fixture of fixtures) {
      const bytes = Buffer.from(fixture.base64, 'base64');
      const response = await mf.dispatchFetch('https://source.example/', { method: 'POST', body: bytes });
      if (fixture.error) {
        assert.equal(response.status, 422, fixture.id);
        assert.equal(await response.text(), 'INVALID_ICON_PNG');
      } else {
        assert.equal(response.status, 200, `${fixture.id}: ${response.status === 200 ? '' : await response.text()}`);
        const expected = normalizeIconPNG(bytes);
        assert.equal(expected.width, fixture.size);
        assert.deepEqual(new Uint8Array(await response.arrayBuffer()), expected.png, fixture.id);
      }
    }
  } finally { await mf.dispose(); }
});
