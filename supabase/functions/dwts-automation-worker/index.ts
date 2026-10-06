// JWT verification is disabled ONLY for this endpoint. A dedicated server-only
// secret authenticates every request; no browser CORS or public mutations.
type Configuration = { url: string; serviceKey: string; workerSecret: string };
type Body = Record<string, unknown>;
const modes = ['get-weeks', 'pre-show', 'live-show', 'post-show', 'photos'];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: {
    'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store',
  } });
}

async function secretsMatch(supplied: string, expected: string) {
  const encode = new TextEncoder();
  const [a, b] = await Promise.all([supplied, expected].map(async (value) =>
    new Uint8Array(await crypto.subtle.digest('SHA-256', encode.encode(value)))));
  let different = 0;
  for (let i = 0; i < a.length; i++) different |= a[i] ^ b[i];
  return different === 0;
}

export function createHandler(config: Configuration, send: typeof fetch = fetch) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'POST') return json({ error: 'POST required' }, 405);
    if (!config.url || !config.serviceKey || config.workerSecret.length < 32) {
      return json({ error: 'Worker endpoint is not configured' }, 503);
    }
    const supplied = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '') || '';
    if (!supplied || supplied.length > 512 || !(await secretsMatch(supplied, config.workerSecret))) {
      return json({ error: 'Unauthorized' }, 401);
    }
    let body: Body;
    try {
      const raw = await request.arrayBuffer();
      if (raw.byteLength > 2_000_000) return json({ error: 'Request too large' }, 413);
      body = JSON.parse(new TextDecoder().decode(raw));
      if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error();
    } catch { return json({ error: 'Invalid JSON object' }, 400); }
    if (typeof body.worker !== 'string' || !body.worker.trim() || body.worker.length > 100) {
      return json({ error: 'Invalid worker name' }, 400);
    }
    let name: string;
    let args: Body = { p_worker: body.worker };
    switch (body.action) {
      case 'claim': name = 'claim_dwts_work'; break;
      case 'heartbeat':
        name = 'heartbeat_dwts_worker';
        if (body.run_id != null) {
          if (typeof body.run_id !== 'string' || !uuid.test(body.run_id)) return json({ error: 'Invalid run ID' }, 400);
          args.p_run = body.run_id;
        }
        break;
      case 'report':
      case 'reconcile':
        if (typeof body.run_id !== 'string' || !uuid.test(body.run_id)) return json({ error: 'Invalid run ID' }, 400);
        args.p_run = body.run_id;
        if (body.action === 'report') {
          if (!body.result || typeof body.result !== 'object' || Array.isArray(body.result)) return json({ error: 'Invalid result' }, 400);
          name = 'report_dwts_work'; args.p_result = body.result;
        } else {
          if (!Array.isArray(body.verified)) return json({ error: 'Invalid verified photos' }, 400);
          name = 'reconcile_dwts_photos'; args.p_verified = body.verified;
        }
        break;
      case 'preview':
        if (!Number.isInteger(body.week) || Number(body.week) < 1 || Number(body.week) > 100
          || typeof body.mode !== 'string' || !modes.includes(body.mode)) return json({ error: 'Invalid preview week/mode' }, 400);
        if (body.week_tag != null && (typeof body.week_tag !== 'string' || body.week_tag.length > 250)) return json({ error: 'Invalid week tag' }, 400);
        name = 'preview_dwts_work';
        args = { p_week_number: body.week, p_mode: body.mode, p_week_tag: body.week_tag || null };
        break;
      default: return json({ error: 'Unknown action' }, 400);
    }
    try {
      const response = await send(`${config.url}/rest/v1/rpc/${name}`, {
        method: 'POST', signal: AbortSignal.timeout(30_000),
        headers: { apikey: config.serviceKey, authorization: `Bearer ${config.serviceKey}`, 'content-type': 'application/json' },
        body: JSON.stringify(args),
      });
      const data = await response.json();
      if (!response.ok) {
        let message = typeof data.message === 'string' ? data.message.slice(0, 1000) : 'Database request failed';
        for (const secret of [config.serviceKey, config.workerSecret]) message = message.replaceAll(secret, '[REDACTED]');
        return json({ error: message }, /lease expired|Unknown run/i.test(message) ? 409 : 422);
      }
      return json(data);
    } catch { return json({ error: 'Database temporarily unavailable' }, 503); }
  };
}

if (import.meta.main) {
  Deno.serve(createHandler({
    url: Deno.env.get('SUPABASE_URL') || '',
    serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '',
    workerSecret: Deno.env.get('DWTS_AUTOMATION_WORKER_SECRET') || '',
  }));
}
