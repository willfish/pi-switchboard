import { decodeExactJson, DiscoveryError } from './protocol.js';
import { decodeEventPage } from './operator-events.js';

// Complete raw framing, including comments and optional LF after CR, is charged
// before a page can be exposed. A CR-delimited final blank line is deferred.
export function createObservationParser(onPage, onActivity = () => {}) {
  const buffer = new Uint8Array(524288);
  let used = 0, lineLength = 0, cr = false, pending = false, previous = null;
  const fail = code => { throw new DiscoveryError(code); };
  function append(byte) { if (used >= buffer.length) fail('limit'); buffer[used++] = byte; }
  function dispatch() {
    const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(buffer.subarray(0, used));
    let event = '', data = [], comment = false;
    for (const line of text.split(/\r\n|\r|\n/)) {
      if (!line) continue;
      if (line.startsWith(':')) { comment = true; continue; }
      const colon = line.indexOf(':');
      const field = colon < 0 ? line : line.slice(0, colon);
      let value = colon < 0 ? '' : line.slice(colon + 1); if (value.startsWith(' ')) value = value.slice(1);
      if (field === 'event') { if (event) fail('schema'); event = value; }
      else if (field === 'data') data.push(value);
      else fail('schema');
    }
    used = 0; lineLength = 0; cr = false; pending = false;
    if (!event && !data.length && comment) { onActivity(); return; }
    const bytes = new TextEncoder().encode(data.join('\n'));
    if (event === 'reset') {
      const value = decodeExactJson(bytes);
      if (!value || Object.keys(value).length !== 1 || !['epoch_reset', 'history_lost', 'capacity'].includes(value.reason)) fail('schema');
      fail('history');
    }
    if (event !== 'observation') fail('schema');
    const page = decodeEventPage(bytes);
    if (previous && (page.epoch !== previous.epoch || page.fromSequence !== previous.toSequence)) fail('history');
    previous = page; onActivity(); onPage(page);
  }
  function byte(value) {
    if (cr) {
      cr = false;
      if (value === 10) { append(value); if (pending) dispatch(); return; }
      if (pending) dispatch();
    }
    append(value);
    if (value === 13) { pending = lineLength === 0; lineLength = 0; cr = true; }
    else if (value === 10) { if (lineLength === 0) dispatch(); else lineLength = 0; }
    else lineLength++;
  }
  return {
    push(chunk) { if (!(chunk instanceof Uint8Array)) fail('schema'); for (const value of chunk) byte(value); },
    end() { if (cr && pending) dispatch(); else if (used) fail('transport'); },
  };
}
