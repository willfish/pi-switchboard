import { createConnection } from 'node:net';
import { randomUUID } from 'node:crypto';

type Environment = Record<string, string | undefined>;
type Call = (method: string, params: Record<string, string>) => Promise<unknown>;

export const HERDR_LABEL_ENTRY = 'agent-bus-herdr-label';
export type TabOwnership = { socket: string; pane: string; tab: string; label: string };
type Pane = { pane_id?: string; tab_id?: string; workspace_id?: string };

/** Only the oldest pane owns a shared tab. Manual names always win over automation. */
export async function nameUnlabelledTab(label: string, env: Environment, call: Call = (method, params) =>
  herdrCall(env.HERDR_SOCKET_PATH!, method, params), options: {
    previous?: TabOwnership; isCurrent?: () => boolean;
  } = {}): Promise<TabOwnership | void> {
  const current = options.isCurrent ?? (() => true);
  if (env.HERDR_ENV !== '1' || !env.HERDR_SOCKET_PATH || !env.HERDR_PANE_ID || !label || !current()) return;
  if (/[\u0000-\u001f\u007f-\u009f<>]/.test(label)) return;
  const paneResult = await call('pane.get', { pane_id: env.HERDR_PANE_ID }) as { pane?: Pane };
  const pane = paneResult?.pane;
  if (!pane?.tab_id || !pane.pane_id || !pane.workspace_id || !current()) return;
  // Resolve the tab from the caller pane, never from UI focus or the inherited tab ID.
  const peers = await call('pane.list', { workspace_id: pane.workspace_id }) as { panes?: Pane[] };
  const members = peers?.panes?.filter(p => p.tab_id === pane.tab_id && typeof p.pane_id === 'string')
    .sort((a, b) => a.pane_id!.localeCompare(b.pane_id!, 'en', { numeric: true }));
  if (members?.[0]?.pane_id !== pane.pane_id || !current()) return;
  const tabResult = await call('tab.get', { tab_id: pane.tab_id }) as { tab?: { label?: unknown } };
  const shown = tabResult?.tab?.label;
  const previous = options.previous;
  const owned = previous?.socket === env.HERDR_SOCKET_PATH && previous.pane === pane.pane_id && previous.tab === pane.tab_id && previous.label === shown;
  if (typeof shown !== 'string' || (!/^[0-9]+$/.test(shown) && !owned) || !current()) return;
  const prefix = shown.match(/^[0-9]+/)?.[0];
  if (!prefix) return;
  const next = `${prefix} ${Array.from(label).slice(0, 48).join('')}`;
  const ownership = { socket: env.HERDR_SOCKET_PATH, pane: pane.pane_id, tab: pane.tab_id, label: next };
  if (next === shown) return ownership;
  // Herdr has no conditional rename. Recheck immediately before the write and fence stale callbacks.
  const latestPane = await call('pane.get', { pane_id: pane.pane_id }) as { pane?: Pane };
  const latestTab = await call('tab.get', { tab_id: pane.tab_id }) as { tab?: { label?: unknown } };
  if (latestPane?.pane?.tab_id !== pane.tab_id || latestTab?.tab?.label !== shown || !current()) return;
  await call('tab.rename', { tab_id: pane.tab_id, label: next });
  return current() ? ownership : undefined;
}

function herdrCall(socketPath: string, method: string, params: Record<string, string>): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const id = randomUUID();
    const socket = createConnection(socketPath);
    let data = '';
    let settled = false;
    const finish = (error?: Error, result?: unknown) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) reject(error); else resolve(result);
    };
    const timer = setTimeout(() => finish(new Error('Herdr request timed out')), 500);
    timer.unref?.();
    socket.on('connect', () => socket.write(`${JSON.stringify({ id, method, params })}\n`));
    socket.on('error', (error) => finish(error));
    socket.on('end', () => finish(new Error('Herdr closed before response')));
    socket.on('data', (chunk: Buffer) => {
      data += chunk.toString('utf8');
      if (Buffer.byteLength(data) > 65536) { finish(new Error('Herdr response too large')); return; }
      const newline = data.indexOf('\n');
      if (newline < 0) return;
      try {
        const response = JSON.parse(data.slice(0, newline));
        if (response.id !== id || !Object.hasOwn(response, 'result') || Object.hasOwn(response, 'error'))
          throw new Error('Invalid Herdr response');
        finish(undefined, response.result);
      } catch (error) { finish(error as Error); }
    });
  });
}
