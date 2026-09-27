import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { plainLabel } from '../hub/priv/dashboard/operator-actions.js';

test('plain display names do not replace wire values', async () => {
  const html = await readFile(new URL('../hub/priv/dashboard/index.html', import.meta.url), 'utf8');
  assert.match(html, /<option value="queued">Waiting<\/option>/);
  assert.match(html, /<option value="implementing">Working<\/option>/);
  assert.match(html, /<option value="label">Rename agent<\/option>/);
  assert.equal(plainLabel('sessionRead'), 'Conversation');
  assert.equal(plainLabel('session.current.read.v1'), 'View conversation');
  assert.equal(plainLabel('work.assign.v1'), 'Assign tasks');
  assert.equal(plainLabel('some-future-value'), 'some-future-value');
});

test('headings use everyday language', async () => {
  const html = await readFile(new URL('../hub/priv/dashboard/index.html', import.meta.url), 'utf8');
  assert.match(html, /<h1>Operator workspace<\/h1>/);
  assert.match(html, />Activity log<\/button>/);
  assert.match(html, /id="view-channels"[^>]*aria-pressed="true"/);
  assert.match(html, /Post as Operator/);
  assert.match(html, /Posts do not wake agents/);
  assert.match(html, /Limit: 4 KiB of UTF-8 text/);
  assert.match(html, /id="channel-check-outcome"[^>]*hidden/);
  assert.match(html, /id="channel-new-intent"[^>]*hidden/);
  assert.doesNotMatch(html, /id="channel-log"[^>]*aria-live/);
  assert.doesNotMatch(html, /<button[^>]*role="listitem"/);
  assert.doesNotMatch(html, />[^<]*(?:Runtime|presence|Volatile observation|Intervention composer)[^<]*</);
});
