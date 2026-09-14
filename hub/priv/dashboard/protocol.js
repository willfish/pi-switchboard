// Kept wire-compatible with extension/protocol.ts and docs/protocol.md.
export const LIMITS = Object.freeze({ pageBytes: 1024 * 1024, stageBytes: 256 * 1024 * 1024,
  records: 5000, pageRecords: 128, requestMs: 5000, overallMs: 30000 });
const uuid = (v) => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const uint = (v) => Number.isSafeInteger(v) && v >= 0;
const unicode = (v) => !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(v);
const exact = (v, keys) => v !== null && typeof v === 'object' && !Array.isArray(v)
  && Object.keys(v).length === keys.length && keys.every((k) => Object.hasOwn(v, k));
const label = (v, n) => typeof v === 'string' && unicode(v) && [...v].length > 0
  && [...v].length <= n && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u.test(v);
const encoder = new TextEncoder();
export class DiscoveryError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const fail = (code = 'schema') => { throw new DiscoveryError(code); };
export function isAgent(v) {
  return exact(v, ['agentId', 'sessionId', 'host', 'cwd', 'sessionName', 'label', 'model',
    'status', 'pid', 'acceptsControl', 'updatedAt', 'receiving'])
    && uuid(v.agentId) && uuid(v.sessionId)
    && typeof v.host === 'string' && /^[\x20-\x7e]{1,255}$/.test(v.host)
    && typeof v.cwd === 'string' && unicode(v.cwd) && v.cwd.length > 0
    && encoder.encode(v.cwd).length <= 4096 && !/[\u0000-\u001f\u007f-\u009f]/u.test(v.cwd)
    && label(v.sessionName, 200) && label(v.label, 200)
    && (v.model === null || (exact(v.model, ['provider', 'id']) && label(v.model.provider, 200) && label(v.model.id, 512)))
    && ['idle', 'busy'].includes(v.status) && uint(v.pid) && v.pid > 0
    && typeof v.acceptsControl === 'boolean' && typeof v.receiving === 'boolean' && uint(v.updatedAt);
}
export function cursorFor(snapshotId, page) {
  return btoa(`${snapshotId}:${page}`).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}
export function isPage(v) {
  return exact(v, ['epoch', 'revision', 'snapshotId', 'capturedAt', 'page', 'total', 'agents', 'nextCursor'])
    && uuid(v.epoch) && uuid(v.snapshotId)
    && typeof v.revision === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(v.revision)
    && BigInt(v.revision) <= 18446744073709551615n
    && uint(v.capturedAt) && uint(v.page) && uint(v.total) && v.total <= LIMITS.records
    && Array.isArray(v.agents) && v.agents.length <= LIMITS.pageRecords && v.agents.every(isAgent)
    && v.agents.every((a, i) => i === 0 || v.agents[i - 1].agentId < a.agentId)
    && (v.nextCursor === null || (typeof v.nextCursor === 'string'
      && /^[A-Za-z0-9_-]{1,64}$/.test(v.nextCursor) && v.nextCursor === cursorFor(v.snapshotId, v.page + 1)));
}
export function decodePage(bytes) {
  if (bytes.byteLength > LIMITS.pageBytes) fail('limit');
  try {
    const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
    const value = JSON.parse(text);
    const containers = [];
    // JSON.parse establishes grammar first; this pass rejects duplicate decoded keys and lone surrogates.
    for (const match of text.matchAll(/"(?:[^"\\]|\\.)*"|[{}\[\]]/g)) {
      const token = match[0];
      if (token === '{') containers.push(new Set());
      else if (token === '[') containers.push(null);
      else if (token === '}' || token === ']') containers.pop();
      else {
        const string = JSON.parse(token);
        if (!unicode(string)) fail();
        if (/^\s*:/.test(text.slice(match.index + token.length))) {
          const keys = containers.at(-1);
          if (!keys || keys.has(string)) fail();
          keys.add(string);
        }
      }
    }
    if (!isPage(value)) fail();
    return value;
  } catch { fail('schema'); }
}

// A traversal owns its staging. Nothing is published until finish succeeds.
export function createStage() {
  let first = null, pageNumber = 0, byteCount = 0, previous = '', finished = false;
  const agents = [], cursors = new Set();
  return {
    add(page, rawBytes) {
      if (!uint(rawBytes) || rawBytes > LIMITS.pageBytes || byteCount + rawBytes > LIMITS.stageBytes) fail('limit');
      if (finished || !isPage(page) || page.page !== pageNumber) fail();
      if (first && !['epoch', 'revision', 'snapshotId', 'capturedAt', 'total'].every((key) => page[key] === first[key])) fail('reset');
      if (page.agents.length && previous && previous >= page.agents[0].agentId) fail();
      if (agents.length + page.agents.length > page.total) fail();
      if (page.nextCursor !== null && (!page.agents.length || agents.length + page.agents.length >= page.total || cursors.has(page.nextCursor))) fail();
      if (page.nextCursor === null && agents.length + page.agents.length !== page.total) fail();
      if (!first) first = { epoch: page.epoch, revision: page.revision, snapshotId: page.snapshotId,
        capturedAt: page.capturedAt, total: page.total };
      agents.push(...page.agents);
      previous = page.agents.at(-1)?.agentId ?? previous;
      byteCount += rawBytes;
      pageNumber += 1;
      if (page.nextCursor !== null) cursors.add(page.nextCursor);
      else finished = true;
      return page.nextCursor;
    },
    finish() { if (!finished) fail(); return { ...first, agents }; },
  };
}

// Race every await against abort, including mocks/transports that ignore AbortSignal.
function abortable(promise, signal) {
  if (signal.aborted) return Promise.reject(new DiscoveryError('cancelled'));
  return new Promise((resolve, reject) => {
    const abort = () => { cleanup(); reject(new DiscoveryError('cancelled')); };
    const cleanup = () => signal.removeEventListener('abort', abort);
    signal.addEventListener('abort', abort, { once: true });
    Promise.resolve(promise).then((v) => { cleanup(); resolve(v); }, (e) => { cleanup(); reject(e); });
  });
}
export async function discover(token, { signal, fetch: fetcher = globalThis.fetch,
  now = () => performance.now(), setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
  const traversal = new AbortController();
  const cancel = () => traversal.abort();
  signal?.addEventListener('abort', cancel, { once: true });
  if (signal?.aborted) cancel();
  const start = now();
  let timedOut = false;
  const overall = setTimer(() => { timedOut = true; traversal.abort(); }, LIMITS.overallMs);
  const stage = createStage();
  let cursor = null, rawTotal = 0;
  const check = () => {
    if (now() - start >= LIMITS.overallMs) fail('timeout');
    if (traversal.signal.aborted) fail(timedOut ? 'timeout' : 'cancelled');
  };
  try {
    do {
      check();
      const request = new AbortController();
      const abortRequest = () => request.abort();
      traversal.signal.addEventListener('abort', abortRequest, { once: true });
      const requestStart = now();
      const timer = setTimer(() => { timedOut = true; request.abort(); }, LIMITS.requestMs);
      let reader;
      try {
        const response = await abortable(fetcher(`/v1/agents${cursor === null ? '' : `?cursor=${encodeURIComponent(cursor)}`}`, {
          method: 'GET', headers: { Authorization: `Bearer ${token}` }, credentials: 'omit',
          redirect: 'error', cache: 'no-store', mode: 'same-origin', referrerPolicy: 'no-referrer', signal: request.signal,
        }), request.signal);
        check();
        if (response.status === 401) fail('unauthorized');
        if (response.status === 409) fail('reset');
        if (response.status !== 200 || !response.body) fail('transport');
        reader = response.body.getReader();
        // One bounded allocation per page, released after decoding. No repeated concatenation.
        const buffer = new Uint8Array(LIMITS.pageBytes);
        let length = 0;
        for (;;) {
          const { value, done } = await abortable(reader.read(), request.signal);
          check();
          if (now() - requestStart >= LIMITS.requestMs) fail('timeout');
          if (done) break;
          if (!(value instanceof Uint8Array) || length + value.byteLength > LIMITS.pageBytes
            || rawTotal + value.byteLength > LIMITS.stageBytes) fail('limit');
          rawTotal += value.byteLength;
          buffer.set(value, length); length += value.byteLength;
        }
        cursor = stage.add(decodePage(buffer.subarray(0, length)), length);
        check();
        if (now() - requestStart >= LIMITS.requestMs) fail('timeout');
      } finally {
        request.abort();
        if (reader) { Promise.resolve(reader.cancel()).catch(() => {}); }
        clearTimer(timer);
        traversal.signal.removeEventListener('abort', abortRequest);
      }
    } while (cursor !== null);
    check();
    return stage.finish();
  } catch (error) {
    if (timedOut) fail('timeout');
    if (error instanceof DiscoveryError) throw error;
    fail('transport');
  } finally {
    clearTimer(overall);
    signal?.removeEventListener('abort', cancel);
    traversal.abort();
  }
}
