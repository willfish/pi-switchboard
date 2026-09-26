import {
  LIMITS, DiscoveryError, abortable, decodeExactJson, discoverPresence,
} from './protocol.js';

import { decodeEventPage, decodeSearchPage, EVENT_LIMITS } from './operator-events.js';
import { decodeWorkView, decodeWorkPage, WORK_VIEW_BYTES } from './operator-work.js';
import { decodeOperation, decodeOperations } from './operator-actions.js';
import { createObservationParser } from './operator-stream.js';

export const SESSION_LIMITS = Object.freeze({ bootstrapBytes: 2048, requestMs: LIMITS.requestMs });
const PATHS = Object.freeze({
  session: '/dashboard/api/v1/session',
  presence: '/dashboard/api/v1/presence',
  events: '/dashboard/api/v1/events',
  work: '/dashboard/api/v1/work/',
  disconnect: '/dashboard/api/v1/disconnect',
});
const ERRORS = Object.freeze({
  schema: "The server sent a response we couldn't understand.",
  limit: "The server response was too large.",
  timeout: "The request took too long.",
  transport: "Couldn't complete the request.",
  unauthorized: "Your connection needs to be refreshed.",
  disabled: "This server hasn't enabled the dashboard.",
  forbidden: "You don't have permission to do this.",
  unavailable: "The dashboard is temporarily unavailable.",
  disconnected: 'This view is disconnected.',
  cancelled: "The request was cancelled.",
  reset: "Agent details changed while loading. Refresh to try again.",
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
  let eventsFlight = null, eventsSeq = 0, currentEvents = 0;
  let workFlight = null, workSeq = 0, currentWork = 0, actionReadFlight = null;
  let channelFlight = null, channelSeq = 0;
  const preceding = (...flights) => Promise.allSettled(flights.filter(Boolean));
  const mutations = new Set(); let mutationGeneration = 0, observation = null;
  const operationId = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
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

  async function readDocument(url, headers, body, signal, maxBytes, method = 'POST', decode = decodeSession) {
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
        method, headers, body, ...sameOrigin, signal: request.signal,
      }), request.signal);
      check();
      if (maxBytes === 0) {
        if (response.status !== 204) fail('transport');
        return;
      }
      if (method === 'POST' && decode !== decodeSession && [400, 404, 409, 413, 429].includes(response.status)) fail('rejected');
      if (method === 'GET' && response.status === 409) fail('history');
      if (method === 'GET' && response.status === 404) fail('not_found');
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
      return decode(bytes);
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

  async function runPresence(id, precedingEvents) {
    if (precedingEvents) await precedingEvents.catch(() => {});
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
    const own = runPresence(id, preceding(eventsFlight?.promise, workFlight?.promise, actionReadFlight?.promise));
    presenceFlight = own;
    void own.finally(() => { if (presenceFlight === own) presenceFlight = null; }).catch(() => {});
    return own;
  }

  async function runRead(path, decode, maxBytes, isCurrent, precedingPresence, deadline = Infinity) {
    const invalid = () => !isCurrent() || userDisconnected;
    if (precedingPresence) await precedingPresence.catch(() => {});
    if (invalid()) fail('cancelled');
    if (flight) await flight.catch(() => {});
    if (invalid()) fail('cancelled');
    if (!nonce) await connect();
    if (invalid()) fail('cancelled');
    const gen = generation;
    const request = new AbortController();
    active = request;
    const deadlineTimer = Number.isFinite(deadline) ? setTimer(() => request.abort(), Math.max(0, deadline - now())) : null;
    const check = () => {
      if (now() >= deadline) fail('timeout');
      if (invalid() || dead(gen, request)) fail('cancelled');
    };
    try {
      for (let attempt = 0; ; attempt++) {
        check();
        try {
          const result = await readDocument(path, { 'X-Switchboard-Session': nonce }, undefined,
            request.signal, maxBytes, 'GET', decode);
          check();
          return result;
        } catch (caught) {
          check();
          if (caught?.code !== 'unauthorized' || attempt !== 0) throw caught;
          nonce = '';
          const issued = await trackBootstrap(request.signal);
          check();
          nonce = issued;
        }
      }
    } finally {
      if (deadlineTimer !== null) clearTimer(deadlineTimer);
      request.abort();
      if (active === request) active = null;
    }
  }

  function events(cursor = 'first') {
    if (userDisconnected) return Promise.reject(new DiscoveryError('disconnected'));
    if (cursor !== 'first' && (typeof cursor !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(cursor)))
      return Promise.reject(new DiscoveryError('schema'));
    if (eventsFlight) return eventsFlight.cursor === cursor ? eventsFlight.promise
      : Promise.reject(new DiscoveryError('busy'));
    const id = ++eventsSeq;
    currentEvents = id;
    const path = PATHS.events + (cursor === 'first' ? '' : `?cursor=${cursor}`);
    const promise = runRead(path, bytes => decodeEventPage(bytes, cursor), EVENT_LIMITS.pageBytes,
      () => currentEvents === id, preceding(presenceFlight, workFlight?.promise, actionReadFlight?.promise));
    const own = { cursor, promise };
    eventsFlight = own;
    void promise.finally(() => { if (eventsFlight === own) eventsFlight = null; }).catch(() => {});
    return promise;
  }

  function searchEvents(filters = {}, cursor = null, prior = null) {
    if (userDisconnected) return Promise.reject(new DiscoveryError('disconnected'));
    const allowed = ['q', 'participant', 'workId', 'threadId', 'outcome', 'from', 'to'];
    if (Object.keys(filters).some(k => !allowed.includes(k)) || Object.values(filters).some(v => typeof v !== 'string'))
      return Promise.reject(new DiscoveryError('schema'));
    if (filters.q && new TextEncoder().encode(filters.q).length > 200) return Promise.reject(new DiscoveryError('limit'));
    if (cursor !== null && (typeof cursor !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(cursor))) return Promise.reject(new DiscoveryError('schema'));
    const query = new URLSearchParams();
    for (const key of allowed) if (filters[key]) query.set(key, filters[key]);
    if (cursor !== null) query.set('cursor', cursor);
    const path = `/dashboard/api/v1/search${query.size ? `?${query}` : ''}`;
    if (eventsFlight) return eventsFlight.cursor === path ? eventsFlight.promise : Promise.reject(new DiscoveryError('busy'));
    const id = ++eventsSeq; currentEvents = id;
    const promise = runRead(path, bytes => decodeSearchPage(bytes, prior), EVENT_LIMITS.pageBytes,
      () => currentEvents === id, preceding(presenceFlight, workFlight?.promise, actionReadFlight?.promise));
    const own = { cursor: path, promise }; eventsFlight = own;
    void promise.finally(() => { if (eventsFlight === own) eventsFlight = null; }).catch(() => {});
    return promise;
  }

  function work(agentId) {
    if (userDisconnected) return Promise.reject(new DiscoveryError('disconnected'));
    if (typeof agentId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(agentId))
      return Promise.reject(new DiscoveryError('schema'));
    if (workFlight) return workFlight.agentId === agentId ? workFlight.promise
      : Promise.reject(new DiscoveryError('busy'));
    const id = ++workSeq; currentWork = id;
    const promise = runRead(PATHS.work + agentId, bytes => decodeWorkView(bytes, agentId), WORK_VIEW_BYTES,
      () => currentWork === id, preceding(presenceFlight, eventsFlight?.promise, actionReadFlight?.promise));
    const own = { agentId, promise }; workFlight = own;
    void promise.finally(() => { if (workFlight === own) workFlight = null; }).catch(() => {});
    return promise;
  }

  async function runFleet(id, before) {
    await before;
    const current = () => currentWork === id && !userDisconnected;
    if (!current()) fail('cancelled');
    const deadline = now() + 30000, views = [];
    let first = null, cursor = null, pageIndex = 0, used = 0;
    do {
      if (!current()) fail('cancelled');
      if (now() >= deadline) fail('timeout');
      const path = '/dashboard/api/v1/work' + (cursor === null ? '' : `?cursor=${cursor}`);
      const page = await runRead(path, bytes => {
        used += bytes.byteLength;
        if (used > 128 * 1024 * 1024) fail('limit');
        return decodeWorkPage(bytes);
      }, 1048576, current, null, deadline);
      if (!current()) fail('cancelled');
      if (page.page !== pageIndex++) fail();
      if (first && ['epoch', 'snapshotId', 'revision', 'capturedAt', 'total'].some(k => first[k] !== page[k])) fail('history');
      first ??= page;
      if (views.length && page.snapshots.length && views.at(-1).binding.agentId >= page.snapshots[0].binding.agentId) fail();
      views.push(...page.snapshots);
      if (views.length > 5000 || views.length > page.total) fail('limit');
      cursor = page.nextCursor;
      if (cursor !== null && (!page.snapshots.length || views.length >= page.total)) fail();
      if (cursor === null && views.length !== page.total) fail();
    } while (cursor !== null);
    if (now() >= deadline) fail('timeout');
    return { epoch: first.epoch, revision: first.revision, capturedAt: first.capturedAt, views };
  }
  function fleet() {
    if (userDisconnected) return Promise.reject(new DiscoveryError('disconnected'));
    if (workFlight) return workFlight.agentId === '*' ? workFlight.promise : Promise.reject(new DiscoveryError('busy'));
    const id = ++workSeq; currentWork = id;
    const promise = runFleet(id, preceding(presenceFlight, eventsFlight?.promise, actionReadFlight?.promise));
    const own = { agentId: '*', promise }; workFlight = own;
    void promise.finally(() => { if (workFlight === own) workFlight = null; }).catch(() => {});
    return promise;
  }

  async function mutateOperation(path, body, id) {
    if (userDisconnected) fail('disconnected');
    if (!operationId(id)) fail();
    const encoded = JSON.stringify(body);
    if (new TextEncoder().encode(encoded).length > 32768) fail('limit');
    if (mutations.size >= 4) fail('busy');
    const request = new AbortController(), epoch = mutationGeneration;
    mutations.add(request); let dispatched = false;
    try {
      if (flight) await flight;
      if (epoch !== mutationGeneration || userDisconnected || request.signal.aborted) fail('cancelled');
      if (!nonce) await connect({ signal: request.signal });
      if (epoch !== mutationGeneration || userDisconnected || request.signal.aborted) fail('cancelled');
      dispatched = true;
      const result = await readDocument(path, { 'content-type': 'application/json', 'X-Switchboard-Session': nonce },
        encoded, request.signal, 1048576, 'POST', bytes => decodeOperation(bytes, id));
      if (epoch !== mutationGeneration || userDisconnected || request.signal.aborted) fail('cancelled');
      return result;
    } catch (error) {
      if (dispatched && !['rejected', 'unauthorized', 'forbidden'].includes(error?.code)) fail('outcome_unknown');
      throw error;
    } finally { mutations.delete(request); request.abort(); }
  }
  function operationRead(path, decode) {
    if (userDisconnected) return Promise.reject(new DiscoveryError('disconnected'));
    if (actionReadFlight) return actionReadFlight.path === path ? actionReadFlight.promise : Promise.reject(new DiscoveryError('busy'));
    const epoch = mutationGeneration;
    const promise = runRead(path, decode, 1048576, () => mutationGeneration === epoch,
      preceding(presenceFlight, eventsFlight?.promise, workFlight?.promise));
    const own = { path, promise }; actionReadFlight = own;
    void promise.finally(() => { if (actionReadFlight === own) actionReadFlight = null; }).catch(() => {});
    return promise;
  }
  const createOperation = doc => mutateOperation('/dashboard/api/v1/operations', doc, doc.operationId);
  const cancelOperation = id => mutateOperation(`/dashboard/api/v1/operations/${id}/cancel`, {}, id);
  function operationStatus(id) {
    if (!operationId(id)) return Promise.reject(new DiscoveryError('schema'));
    return operationRead(`/dashboard/api/v1/operations/${id}`, bytes => decodeOperation(bytes, id));
  }
  function operations(agentId) {
    if (!operationId(agentId)) return Promise.reject(new DiscoveryError('schema'));
    return operationRead(`/dashboard/api/v1/operations?agentId=${agentId}`, bytes => decodeOperations(bytes, agentId));
  }

  async function observe({ signal, onPage, onUpdate = () => {} }) {
    if (userDisconnected) fail('disconnected');
    if (observation) fail('busy');
    const request = new AbortController(); observation = request;
    const cancel = () => request.abort(); signal?.addEventListener('abort', cancel, { once: true });
    if (signal?.aborted) request.abort();
    const epoch = mutationGeneration;
    let reader, timer = null, deadline = now() + 5000, issued = '', timedOut = false;
    const arm = ms => { if (timer !== null) clearTimer(timer); deadline = now() + ms;
      timer = setTimer(() => { timedOut = true; request.abort(); }, ms); };
    const check = () => {
      if (timedOut || now() >= deadline) fail('timeout');
      if (request.signal.aborted || userDisconnected || mutationGeneration !== epoch || issued && issued !== nonce) fail('cancelled');
    };
    try {
      if (flight) await abortable(flight, request.signal);
      if (!nonce) await connect({ signal: request.signal });
      if (request.signal.aborted || userDisconnected || mutationGeneration !== epoch) fail('cancelled');
      issued = nonce; arm(5000);
      const response = await abortable(fetcher('/dashboard/api/v1/stream', { ...sameOrigin, method: 'GET',
        headers: { 'X-Switchboard-Session': issued, accept: 'text/event-stream', 'X-Switchboard-Updates': '1' }, signal: request.signal }), request.signal);
      check();
      if (response.status === 401) { nonce = ''; fail('unauthorized'); }
      if (response.status === 403) fail('forbidden');
      if (response.status !== 200 || !response.body || !/^text\/event-stream(?:;|$)/i.test(response.headers.get('content-type') ?? '')) fail('unavailable');
      arm(30000);
      const parser = createObservationParser(page => { check(); onPage(page); }, () => { check(); arm(30000); }, () => { check(); onUpdate(); });
      reader = response.body.getReader();
      for (;;) {
        const chunk = await abortable(reader.read(), request.signal); check();
        if (chunk.done) { parser.end(); fail('transport'); }
        parser.push(chunk.value);
      }
    } finally {
      if (timer !== null) clearTimer(timer);
      request.abort(); if (reader) Promise.resolve(reader.cancel()).catch(() => {});
      signal?.removeEventListener('abort', cancel);
      if (observation === request) observation = null;
    }
  }

  async function disconnect() {
    const issued = nonce;
    const bootId = pendingBootstrap;
    nonce = '';
    userDisconnected = true;
    generation += 1;
    mutationGeneration++; observation?.abort();
    for (const mutation of mutations) mutation.abort();
    mutations.clear();
    currentPresence = 0;
    currentEvents = 0;
    eventsFlight = null;
    currentWork = 0;
    workFlight = null;
    actionReadFlight = null;
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

  function channelPath(path) {
    let url;
    try { url = new URL(path, 'http://dashboard.local'); } catch { return false; }
    if (url.origin !== 'http://dashboard.local' || url.username || url.hash) return false;
    if (url.pathname === '/dashboard/api/v1/channels') return url.search === '';
    const match = /^\/dashboard\/api\/v1\/channels\/([a-z][a-z0-9-]{0,31})\/(messages|status)$/.exec(url.pathname);
    if (!match) return false;
    if (match[2] === 'status') return url.search === '';
    const keys = [...url.searchParams.keys()];
    return keys.every(key => key === 'after' || key === 'before' || key === 'limit')
      && !(url.searchParams.has('after') && url.searchParams.has('before'));
  }
  function decodeChannelObject(bytes) {
    if (bytes.byteLength > 1048576) fail('limit');
    const value = decodeExactJson(bytes);
    if (!value || typeof value !== 'object' || Array.isArray(value)) fail();
    return value;
  }
  function channelRead(path) {
    if (userDisconnected) return Promise.reject(new DiscoveryError('disconnected'));
    if (!channelPath(path)) return Promise.reject(new DiscoveryError('schema'));
    if (channelFlight) return channelFlight.path === path ? channelFlight.promise : Promise.reject(new DiscoveryError('busy'));
    const id = ++channelSeq;
    const promise = runRead(path, decodeChannelObject, 1048576, () => channelSeq === id && !userDisconnected, preceding(presenceFlight));
    const own = { path, promise };
    channelFlight = own;
    void promise.finally(() => { if (channelFlight === own) channelFlight = null; }).catch(() => {});
    return promise;
  }

  return { connect, presence, events, searchEvents, work, fleet, createOperation, operationStatus, cancelOperation, operations, observe, channelRead, disconnect };
}
