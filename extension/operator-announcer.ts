import type { AnnounceOutcome } from './client.ts';
import { isAnnouncement, isBindingFor, type OperatorAnnouncement, type OperatorBinding } from './operator-binding.ts';

export type AnnouncementSnapshot = Omit<OperatorAnnouncement, 'registration' | 'reportRevision'>;

// Called by the existing heartbeat after successful registration. No timers or
// network work at construction, and no dependency on lease renewal completing it.
export function createAnnouncer(options: {
  snapshot(): AnnouncementSnapshot;
  send(document: OperatorAnnouncement, signal: AbortSignal): Promise<AnnounceOutcome>;
  now?: () => number;
  onBinding?: (binding: OperatorBinding | null) => void;
}) {
  const now = options.now ?? (() => performance.now());
  const lifetime = new AbortController();
  let stopped = false, flight: Promise<void> | null = null, binding: OperatorBinding | null = null;
  let signature = '', revision = 0n, probeAt = 0, retryAt = 0;
  function publish(value: OperatorBinding | null) {
    binding = value;
    try { options.onBinding?.(value); } catch { /* Observation cannot alter transport. */ }
  }
  async function run() {
    if (stopped || now() < retryAt) return;
    try {
      const base = JSON.stringify(options.snapshot());
      const captured = { ...JSON.parse(base), registration: binding?.registration ?? null };
      const next = JSON.stringify(captured);
      if (next === signature && now() < probeAt) return;
      if (next !== signature) {
        if (revision === 18446744073709551615n) { stop(); return; }
        revision++;
      }
      const document = { ...captured, reportRevision: String(revision) };
      if (!isAnnouncement(document)) throw new Error('invalid report');
      const result = await options.send(document, lifetime.signal);
      if (stopped) return;
      if (JSON.stringify(options.snapshot()) !== base) {
        signature = ''; probeAt = 0; retryAt = 0; publish(null); return;
      }
      if (result.status === 'ok' && isBindingFor(result.binding, document)) {
        signature = next; retryAt = 0; probeAt = now() + 30000;
        publish(result.binding);
      } else {
        signature = ''; retryAt = now() + 30000;
        publish(null);
      }
    } catch {
      if (!stopped) { signature = ''; retryAt = now() + 30000; publish(null); }
    }
  }
  function tick(): Promise<void> {
    if (stopped) return Promise.resolve();
    if (flight) return flight;
    const own = run(); flight = own;
    void own.finally(() => { if (flight === own) flight = null; }).catch(() => {});
    return own;
  }
  function stop() {
    stopped = true; lifetime.abort(); binding = null;
  }
  return { tick, stop };
}
