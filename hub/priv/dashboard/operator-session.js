import {
  LIMITS, DiscoveryError, abortable, decodeExactJson, discoverPresence,
} from './protocol.js';

export const SESSION_LIMITS = Object.freeze({ bootstrapBytes: 2048, requestMs: LIMITS.requestMs });
const PATHS = Object.freeze({
  session: '/dashboard/api/v1/session',
  presence: '/dashboard/api/v1/presence',
  disconnect: '/dashboard/api/v1/disconnect',
});
const ERRORS = Object.freeze({
  schema: 'The hub returned an invalid operator document.',
  limit: 'The operator response exceeded its size limit.',
  timeout: 'The operator request exceeded its time limit.',
  transport: 'Could not complete the operator request.',
  unauthorized: 'The operator session was rejected.',
  disabled: 'Operator access is disabled on this hub.',
  forbidden: 'Operator access was denied for this request.',
  unavailable: 'Operator access is temporarily unavailable.',
  disconnected: 'This view is disconnected.',
  cancelled: 'The operator request was cancelled.',
  reset: 'Presence changed during the read. Refresh to try a new snapshot.',
});
const sameOrigin = { credentials: 'omit', redirect: 'error', cache: 'no-store', mode: 'same-origin',
  referrerPolicy: 'no-referrer' };
const fail = (code = 'schema') => { throw new DiscoveryError(code); };
const isSession = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)
  && Object.keys(v).length === 1 && Object.hasOwn(v, 'session')
  && typeof v.session === 'string' && /^[0-9a-f]{64}$/.test(v.session);

function decodeSession(bytes) {
  if (bytes.byteLength > SESSION_LIMITS.bootstrapBytes) fail('limit');
  if (bytes.byteLength >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) fail();
  const value = decodeExactJson(bytes);
  if (!isSession(value)) fail();
  return value.session;
}

export function createOperatorSession({ fetch: fetcher = globalThis.fetch, now = () => performance.now(),
  setTimer = setTimeout, clearTimer = clearTimeout, render = () => {} } = {}) {
  let generation = 0, nonce = '', flight = null, presenceFlight = null, active = null, userDisconnected = true;
  let bootstrapSeq = 0, pendingBootstrap = 0, presenceSeq = 0, currentPresence = 0;
  let status = 'disconnected', snapshot = null, error = '', invalidation = null;
  const emit = () => render({ status, snapshot, error, invalidation });
  const asError = (error) => error instanceof DiscoveryError ? error : new DiscoveryError('transport');
  const stale = (gen) => generation !== gen || userDisconnected;
  const dead = (gen, request) => stale(gen) || request.signal.aborted;
  function trackBootstrap(signal) {
    const id = ++bootstrapSeq;
    pendingBootstrap = id;
    return bootstrap(signal).finally(() => { if (pendingBootstrap === id) pendingBootstrap = 0; });
  }
  const failRead = (err) => {
    if (err.code === 'unauthorized') nonce = '';
    snapshot = null; status = 'failed'; error = ERRORS[err.code] ?? ERRORS.transport; emit();
    throw err;
  };
  emit();

  async function readDocument(url, headers, body, signal, maxBytes) {
    const request = new AbortController();
    const abortRequest = () => request.abort();
    signal.addEventListener('abort', abortRequest, { once: true });
    if (signal.aborted) request.abort();
    const start = now();
    let timedOut = false, reader;
    const timer = setTimer(() => { timedOut = true; request.abort(); }, SESSION_LIMITS.requestMs);
    const check = () => {
      if (now() - start >= SESSION_LIMITS.requestMs) fail('timeout');
      if (request.signal.aborted) fail(timedOut ? 'timeout' : 'cancelled');
    };
    try {
      const response = await abortable(fetcher(url, {
        method: 'POST', headers, body, ...sameOrigin, signal: request.signal,
      }), request.signal);
      check();
      if (maxBytes === 0) {
        if (response.status !== 204) fail('transport');
        return;
      }
      if (response.status === 503) fail('unavailable');
      if (response.status === 403 && !response.body) fail('forbidden');
      if (![200, 403].includes(response.status) || !response.body) fail(response.status === 401 ? 'unauthorized' : 'transport');
      reader = response.body.getReader();
      const buffer = new Uint8Array(maxBytes);
      let length = 0;
      for (;;) {
        const { value, done } = await abortable(reader.read(), request.signal);
        check();
        if (done) break;
        if (!(value instanceof Uint8Array) || length + value.byteLength > maxBytes) fail('limit');
        buffer.set(value, length); length += value.byteLength;
      }
      check();
      const bytes = buffer.subarray(0, length);
      if (response.status === 403) {
        let disabled = false;
        try {
          const doc = decodeExactJson(bytes);
          const detail = doc?.error;
          disabled = doc !== null && typeof doc === 'object' && !Array.isArray(doc)
            && Object.keys(doc).length === 1 && Object.hasOwn(doc, 'error')
            && detail !== null && typeof detail === 'object' && !Array.isArray(detail)
            && Object.keys(detail).length === 2 && Object.hasOwn(detail, 'code')
            && Object.hasOwn(detail, 'message') && typeof detail.message === 'string'
            && detail.code === 'disabled';
        } catch { /* Invalid error documents cannot establish the disabled state. */ }
        fail(disabled ? 'disabled' : 'forbidden');
      }
      return decodeSession(bytes);
    } catch (caught) {
      if (timedOut) fail('timeout');
      if (caught instanceof DiscoveryError) throw caught;
      fail('transport');
    } finally {
      request.abort();
      if (reader) Promise.resolve(reader.cancel()).catch(() => {});
      clearTimer(timer);
      signal.removeEventListener('abort', abortRequest);
    }
  }

  function bootstrap(signal) {
    return readDocument(PATHS.session, { 'content-type': 'application/json' }, '{}', signal,
      SESSION_LIMITS.bootstrapBytes);
  }

  function invalidate(issued, signal) {
    return readDocument(PATHS.disconnect,
      { 'content-type': 'application/json', 'X-Switchboard-Session': issued }, '{}', signal, 0);
  }

  async function runConnect({ signal } = {}) {
    const gen = ++generation;
    active?.abort();
    const request = new AbortController();
    active = request;
    const abortFromUser = () => request.abort();
    signal?.addEventListener('abort', abortFromUser, { once: true });
    if (signal?.aborted) request.abort();
    status = 'connecting'; snapshot = null; error = ''; emit();
    try {
      const issued = await trackBootstrap(request.signal);
      if (dead(gen, request)) fail('cancelled');
      nonce = issued;
      status = 'connected';
      emit();
    } catch (caught) {
      const err = asError(caught);
      if (generation !== gen) fail('cancelled');
      nonce = '';
      if (userDisconnected) { status = 'disconnected'; emit(); fail('cancelled'); }
      status = 'failed'; error = ERRORS[err.code] ?? ERRORS.transport; emit();
      throw err;
    } finally {
      signal?.removeEventListener('abort', abortFromUser);
      if (active === request) active = null;
    }
  }

  function connect(opts = {}) {
    userDisconnected = false;
    invalidation = null;
    if (nonce && status === 'connected' && !flight) { emit(); return Promise.resolve(); }
    if (flight) return flight;
    const own = runConnect(opts);
    flight = own;
    void own.finally(() => { if (flight === own) flight = null; }).catch(() => {});
    return own;
  }

  async function loadPresence(signal, issued) {
    return discoverPresence({
      path: PATHS.presence, headers: { 'X-Switchboard-Session': issued }, signal,
      fetch: fetcher, now, setTimer, clearTimer,
    });
  }

  async function runPresence(id) {
    const live = () => currentPresence !== id || userDisconnected;
    if (live()) fail('cancelled');
    if (flight) await flight.catch(() => {});
    if (live()) fail('cancelled');
    if (!nonce) await connect();
    if (live()) fail('cancelled');
    if (!nonce) fail('disconnected');
    const gen = generation;
    const request = new AbortController();
    active = request;
    let retried = false;
    try {
      for (;;) {
        if (live() || dead(gen, request)) fail('cancelled');
        const issued = nonce;
        try {
          const value = await loadPresence(request.signal, issued);
          if (live() || dead(gen, request)) fail('cancelled');
          snapshot = value; error = ''; status = 'connected'; emit();
          return value;
        } catch (caught) {
          if (live() || dead(gen, request)) fail('cancelled');
          const err = asError(caught);
          if (err.code === 'unauthorized' && !retried) {
            retried = true;
            nonce = ''; snapshot = null; emit();
            try {
              const recovered = await trackBootstrap(request.signal);
              if (live() || dead(gen, request)) fail('cancelled');
              nonce = recovered;
              continue;
            } catch (bootCaught) {
              if (live() || dead(gen, request)) fail('cancelled');
              failRead(asError(bootCaught));
            }
          }
          failRead(err);
        }
      }
    } finally {
      if (active === request) active = null;
    }
  }

  function presence() {
    if (userDisconnected) return Promise.reject(new DiscoveryError('disconnected'));
    if (presenceFlight) return presenceFlight;
    const id = ++presenceSeq;
    currentPresence = id;
    const own = runPresence(id);
    presenceFlight = own;
    void own.finally(() => { if (presenceFlight === own) presenceFlight = null; }).catch(() => {});
    return own;
  }

  async function disconnect() {
    const issued = nonce;
    const bootId = pendingBootstrap;
    nonce = '';
    userDisconnected = true;
    generation += 1;
    currentPresence = 0;
    flight = null;
    presenceFlight = null;
    active?.abort();
    active = null;
    snapshot = null; error = ''; status = 'disconnected';
    invalidation = bootId ? 'unknown' : (issued ? 'pending' : null);
    emit();
    if (!issued) return invalidation;
    const gen = generation;
    const request = new AbortController();
    try {
      await invalidate(issued, request.signal);
      if (generation !== gen) return invalidation;
      if (!bootId) { invalidation = 'complete'; emit(); }
      return invalidation;
    } catch {
      if (generation !== gen) return invalidation;
      invalidation = 'unknown'; emit();
      return invalidation;
    } finally {
      request.abort();
    }
  }

  return { connect, presence, disconnect };
}
