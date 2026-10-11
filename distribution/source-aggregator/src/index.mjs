import { Catalog } from './catalog.mjs';
import { json } from './errors.mjs';
import icon from '../assets/icon.png';
export { Catalog };

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === '/health' && request.method === 'GET') return json({ service: 'signos-source-aggregator', version: 1, sourceId: env.SOURCE_ID });
    if (path === '/icon.png' && ['GET', 'HEAD'].includes(request.method)) {
      return new Response(request.method === 'HEAD' ? null : icon, { headers: { 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=86400' } });
    }
    const stub = env.CATALOG.get(env.CATALOG.idFromName(env.SOURCE_ID || 'yao'));
    return stub.fetch(request);
  },
  async scheduled(_controller, env) {
    const stub = env.CATALOG.get(env.CATALOG.idFromName(env.SOURCE_ID || 'yao'));
    await stub.tick();
  },
};
