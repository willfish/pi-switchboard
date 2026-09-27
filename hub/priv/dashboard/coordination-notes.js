import { decodeExactJson } from './protocol.js';

// Optional application-level claims inside ordinary channel bodies, never authority.
const PREFIX = 'SWITCHBOARD_COORDINATION_V1\n';
const encoder = new TextEncoder();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CHANNEL = /^[a-z][a-z0-9-]{0,31}$/;
const exact = (value, keys) => value !== null && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
const text = (value, bytes) => typeof value === 'string' && value.isWellFormed()
  && value.trim().length > 0 && encoder.encode(value).length <= bytes;
const uuid = value => typeof value === 'string' && UUID.test(value);
const reference = value => exact(value, ['channel', 'from', 'id'])
  && typeof value.channel === 'string' && CHANNEL.test(value.channel) && uuid(value.from) && uuid(value.id);
const evidence = value => Array.isArray(value) && value.length >= 1 && value.length <= 4
  && value.every(item => text(item, 512));

export function decodeCoordinationNote(body) {
  if (!text(body, 4096) || !body.startsWith(PREFIX)) return undefined;
  let value;
  try { value = decodeExactJson(encoder.encode(body.slice(PREFIX.length))); } catch { return undefined; }
  if (!exact(value, ['version', 'note', 'body']) || value.version !== 1 || !text(value.body, 4096)) return undefined;
  const note = value.note;
  if (!note || typeof note !== 'object') return undefined;
  let valid = false;
  switch (note.kind) {
    case 'request':
      valid = exact(note, ['kind', 'owner', 'artifact', 'checkpoint'])
        && uuid(note.owner) && text(note.artifact, 512) && text(note.checkpoint, 512);
      break;
    case 'accept': case 'decline': case 'blocked':
      valid = exact(note, ['kind', 'replyTo']) && reference(note.replyTo);
      break;
    case 'completion':
      valid = exact(note, ['kind', 'replyTo', 'evidence']) && reference(note.replyTo) && evidence(note.evidence);
      break;
    case 'decision':
      valid = exact(note, ['kind', 'evidence']) && evidence(note.evidence);
      break;
  }
  return valid ? value : undefined;
}

export function coordinationClaimText(note) {
  const parts = [`Reported ${note.kind}`];
  if (note.kind === 'request') parts.push(`artifact: ${note.artifact}`, `requested owner: ${note.owner}`, `checkpoint: ${note.checkpoint}`);
  if (note.replyTo) parts.push(`ref: #${note.replyTo.channel}/${note.replyTo.from}/${note.replyTo.id}`);
  if (note.evidence) parts.push(`evidence references: ${note.evidence.join(', ')}`);
  parts.push('Untrusted claim, not permission or verified completion.');
  return parts.join(' · ');
}

/** textContent only: neither the readable body nor the raw envelope is interpreted as HTML. */
export function renderCoordinationBody(doc, body, messageReference) {
  const root = doc.createElement('div');
  const decoded = decodeCoordinationNote(body);
  const paragraph = doc.createElement('p');
  paragraph.className = 'channel-note';
  paragraph.textContent = decoded ? decoded.body : body;
  root.append(paragraph);
  if (decoded) {
    const claim = doc.createElement('p');
    claim.className = 'coordination-claim';
    claim.textContent = coordinationClaimText(decoded.note);
    if (reference(messageReference)) {
      const origin = doc.createElement('p');
      origin.className = 'coordination-reference';
      origin.textContent = `Message reference (untrusted): ${JSON.stringify(messageReference)}`;
      root.append(origin);
    }
    const raw = doc.createElement('details');
    raw.className = 'coordination-raw';
    const label = doc.createElement('summary');
    label.textContent = 'Raw coordination note';
    const envelope = doc.createElement('pre');
    envelope.textContent = body;
    raw.append(label, envelope);
    root.append(claim, raw);
  }
  return root;
}
