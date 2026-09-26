import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { isMessagePage, mergeHistory, channelMessagesPath, speaker, OPERATOR_ID, newChannelMessageId } from '../hub/priv/dashboard/channels.js';

test('operator posts are labeled without impersonating an agent', () => {
  assert.equal(speaker({ from: OPERATOR_ID }), 'Operator');
  assert.equal(speaker({ from: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }), 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
});

test('channel composer can mint an id without crypto.randomUUID', () => {
  const uuid = newChannelMessageId();
  assert.match(uuid, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.notEqual(uuid, newChannelMessageId());
  const source = readFileSync(new URL('../hub/priv/dashboard/channels.js', import.meta.url), 'utf8');
  assert.equal(source.includes('crypto.randomUUID('), false);
});

test('operator history can be walked without duplicating packets', () => {
  assert.equal(channelMessagesPath('general', { after: '0' }), '/dashboard/api/v1/channels/general/messages?after=0');
  const older = page(['1', '2']);
  const newer = page(['3', '4']);
  assert.equal(isMessagePage(older, 'general'), true);
  assert.deepEqual(mergeHistory(older.messages, newer, 'append').map(message => message.seq), ['1', '2', '3', '4']);
  assert.deepEqual(mergeHistory(newer.messages, older, 'prepend').map(message => message.seq), ['1', '2', '3', '4']);
  assert.equal(mergeHistory(older.messages, older, 'append').length, 2);
});

function page(seqs) {
  return {
    epoch: '11111111-1111-4111-8111-111111111111', channel: 'general', window: 'history',
    fromSequence: seqs[0], toSequence: seqs.at(-1), retainedFrom: '1', retainedTo: '4',
    coverage: 'complete', caughtUp: seqs.at(-1) === '4', earlier: seqs[0] !== '1',
    nextCursor: seqs.at(-1) === '4' ? null : seqs.at(-1), earlierCursor: seqs[0] === '1' ? null : seqs[0],
    messages: seqs.map(seq => ({ seq, id: '33333333-3333-4333-8333-333333333333', channel: 'general',
      from: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', kind: 'say', body: `note ${seq}`, postedAt: 10 })),
  };
}
