import type { ExtensionContext } from '@earendil-works/pi-coding-agent';

export type SessionProjection = {
  schemaVersion: 1; sessionId: string; leafId: string | null; nextLeafId: string | null;
  records: { entryId: string; role: 'user' | 'assistant' | 'custom' | 'tool-summary'; text: string }[];
  omitted: number; truncated: boolean;
};
const encoder = new TextEncoder();
function preview(value: unknown, maximum = 16384): { text: string; truncated: boolean } {
  if (typeof value !== 'string') return { text: '', truncated: false };
  let text = '', used = 0, consumed = 0;
  for (const original of value) {
    const char = original.length === 1 && /[\ud800-\udfff]/.test(original) ? '\ufffd' : original;
    const bytes = encoder.encode(char).length;
    if (used + bytes > maximum) break;
    text += char; used += bytes; consumed += original.length;
  }
  return { text, truncated: consumed < value.length };
}
function content(value: unknown) {
  if (typeof value === 'string') return preview(value);
  if (!Array.isArray(value)) return { text: '', truncated: true };
  let text = '', truncated = value.length > 128;
  for (const block of value.slice(0, 128)) {
    if (!block || block.type !== 'text') { truncated = true; continue; }
    const part = preview(block.text, Math.max(0, 16384 - encoder.encode(text).length));
    text += part.text; truncated ||= part.truncated;
  }
  return { text, truncated };
}

type Entry = NonNullable<ReturnType<ExtensionContext['sessionManager']['getEntry']>>;
function project(entry: Entry): { record: SessionProjection['records'][number] | null; truncated: boolean } {
  let role: SessionProjection['records'][number]['role'], result: ReturnType<typeof content>;
  if (entry.type === 'message') {
    const message = entry.message;
    if (message.role === 'user' || message.role === 'assistant') {
      role = message.role; result = content(message.content);
    } else if (message.role === 'toolResult') {
      role = 'tool-summary';
      result = { text: `Tool ${preview(message.toolName, 256).text}: ${message.isError ? 'reported error' : 'returned'}. Raw arguments and output omitted.`, truncated: true };
    } else if (message.role === 'custom' && message.display && message.customType === 'agent-bus-mail') {
      role = 'custom'; result = content(message.content);
    } else return { record: null, truncated: true };
  } else if (entry.type === 'custom_message' && entry.display && entry.customType === 'agent-bus-mail') {
    role = 'custom'; result = content(entry.content);
  } else return { record: null, truncated: false };
  return { record: result.text ? { entryId: entry.id, role, text: result.text } : null, truncated: result.truncated };
}

// Continuations are issued handles, not arbitrary session-entry or file paths.
export function createSessionProjection({ now = () => performance.now(), uuid = () => crypto.randomUUID() }: { now?: () => number; uuid?: () => string } = {}) {
  const handles = new Map<string, { sessionId: string; generation: string; root: string | null; next: string; expires: number }>();
  function clear() { handles.clear(); }
  function read(ctx: ExtensionContext, generation: string, requested: string | null, limit = 64): SessionProjection {
    const at = now();
    for (const [key, value] of handles) if (value.expires <= at) handles.delete(key);
    const sessionId = ctx.sessionManager.getSessionId();
    let root = ctx.sessionManager.getLeafId(), next = root, expires = at + 30000;
    if (requested !== null) {
      const cursor = handles.get(requested);
      if (!cursor || cursor.sessionId !== sessionId || cursor.generation !== generation || cursor.expires <= at)
        throw new Error('expired session handle');
      root = cursor.root; next = cursor.next; expires = cursor.expires;
    }
    const page: SessionProjection = { schemaVersion: 1, sessionId, leafId: root, nextLeafId: null, records: [], omitted: 0, truncated: false };
    const seen = new Set<string>(); let used = 0;
    for (let scanned = 0; next !== null && scanned < 2048 && page.records.length < Math.min(64, Math.max(1, limit)); scanned++) {
      if (now() >= expires) throw new Error('session traversal expired');
      if (seen.has(next)) throw new Error('invalid session ancestry');
      seen.add(next);
      const entry = ctx.sessionManager.getEntry(next);
      if (!entry) { page.truncated = true; page.omitted++; next = null; break; }
      // Do not pretend to reconstruct either historical compaction format.
      if (entry.type === 'compaction') { page.truncated = true; page.omitted++; next = null; break; }
      const item = project(entry);
      if (item.record) {
        const charge = encoder.encode(JSON.stringify(item.record)).length + 1;
        if (used + charge > 524288 - 8192) { page.truncated = true; break; }
        page.records.push(item.record); used += charge;
      } else page.omitted++;
      page.truncated ||= item.truncated;
      next = entry.parentId;
    }
    if (next !== null) {
      if (handles.size >= 32) throw new Error('session cursor capacity');
      const handle = uuid();
      handles.set(handle, { sessionId, generation, root, next, expires }); page.nextLeafId = handle;
    }
    // Each page is chronological; subsequent pages walk earlier ancestry.
    page.records.reverse();
    if (encoder.encode(JSON.stringify(page)).length > 524288) throw new Error('session page too large');
    return page;
  }
  return { read, clear };
}
