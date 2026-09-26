import test from 'node:test';
import assert from 'node:assert/strict';
import { isMessagePage, mergeHistory, channelMessagesPath } from '../hub/priv/dashboard/channels.js';

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
