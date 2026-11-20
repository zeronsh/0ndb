import assert from 'node:assert/strict';
import test from 'node:test';
import { applyReasoningDelta, mergeReasoning } from './reasoning.js';

test('streamed Unicode chunks append once and duplicate deliveries are ignored', () => {
  const first = { block: 7, revision: 1, started_ms: 1000, text: 'café ' };
  const blocks = applyReasoningDelta([], first);
  assert.deepEqual(applyReasoningDelta(blocks, first), blocks);
  const next = applyReasoningDelta(blocks, { ...first, revision: 2, text: '🚀' });
  assert.equal(next[0].text, 'café 🚀');
});

test('a page snapshot cannot overwrite newer live content or reopen a completed block', () => {
  const old = { id: 7, revision: 2, text: 'partial', started_ms: 1000, ended_ms: null };
  const finished = { ...old, revision: 5, text: 'complete', ended_ms: 3000 };
  assert.deepEqual(mergeReasoning([old], [finished]), [finished]);
  assert.deepEqual(mergeReasoning([finished], [old]), [finished]);
});

test('missing chunks require a snapshot; completed snapshots can bridge the gap', () => {
  assert.equal(applyReasoningDelta([], { block: 7, revision: 3, text: 'suffix' }), null);
  const snapshot = { id: 7, revision: 8, text: 'whole trace', ended_ms: 5000 };
  assert.deepEqual(mergeReasoning([], [snapshot]), [snapshot]);
});
