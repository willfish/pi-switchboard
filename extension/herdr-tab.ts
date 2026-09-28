import { createConnection } from 'node:net';
import { randomUUID } from 'node:crypto';

type Environment = Record<string, string | undefined>;
type Call = (method: string, params: Record<string, string>) => Promise<unknown>;

/** Herdr's API has no conditional rename, so only rename a tab which still displays its number. */
export async function nameUnlabelledTab(label: string, env: Environment, call: Call = (method, params) =>
  herdrCall(env.HERDR_SOCKET_PATH!, method, params)): Promise<void> {
  if (env.HERDR_ENV !== '1' || !env.HERDR_SOCKET_PATH || !env.HERDR_PANE_ID || !label) return;
  const paneResult = await call('pane.get', { pane_id: env.HERDR_PANE_ID }) as { pane?: { tab_id?: unknown } };
  const tabId = paneResult?.pane?.tab_id;
  if (typeof tabId !== 'string') return;
  const tabResult = await call('tab.get', { tab_id: tabId }) as { tab?: { number?: unknown; label?: unknown } };
  const tab = tabResult?.tab;
  if (!tab || !Number.isSafeInteger(tab.number) || tab.label !== String(tab.number)) return;
  await call('tab.rename', { tab_id: tabId, label: `${tab.number} ${label}` });
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
