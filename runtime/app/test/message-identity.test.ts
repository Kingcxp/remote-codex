import assert from 'node:assert/strict';
import test from 'node:test';
import { internals } from '../src/connector/rollout-tail.js';
import { finishTimelineStream, historyItems, mergeHistorySnapshot } from '../web/src/history-utils.js';

test('paired rollout response/event records retain the native ID used by live snapshots', () => {
  const rows = [
    { type: 'event_msg', payload: { type: 'task_started', turn_id: 'turn' } },
    { type: 'event_msg', timestamp: '2026-11-24T08:00:01Z', payload: { type: 'agent_message', phase: 'final_answer', message: 'done' } },
    { type: 'response_item', timestamp: '2026-11-24T08:00:02Z', payload: { type: 'message', id: 'native-reply', role: 'assistant', phase: 'final_answer', content: [{ type: 'output_text', text: 'done' }] } },
  ];
  const mapped = internals.mapRolloutRows(rows);
  assert.equal(mapped.length, 1);
  assert.equal(mapped[0].id, 'native-reply');
  const native = historyItems([{ id: 'turn', items: [{ id: 'native-reply', type: 'agentMessage', phase: 'final_answer', text: 'done' }] }], 'desktop');
  let items = native;
  for (let i = 0; i < 5; i++) {
    items = mergeHistorySnapshot(items, historyItems([{ id: 'turn', items: mapped }], 'rolloutTail'), new Set(['turn']), { partial: true });
    items = mergeHistorySnapshot(items, native, new Set(['turn']), { partial: true });
    assert.equal(items.length, 1);
  }
});

test('identified reasoning snapshots replace growing text and repeated rollout records once', () => {
  const make = (text: string) => ({ type: 'response_item', payload: { type: 'reasoning', id: 'reason', turn_id: 'turn', summary: [{ text }] } });
  const rows = internals.mapRolloutRows([make('partial'), make('partial complete'), make('partial complete')]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].text, 'partial complete');
  let items = historyItems([{ id: 'turn', items: [{ id: 'reason', type: 'reasoning', text: 'partial' }] }], 'desktop');
  items = mergeHistorySnapshot(items, historyItems([{ id: 'turn', items: rows }], 'rolloutTail'), new Set(['turn']), { partial: true });
  assert.equal(items.length, 1);
  assert.equal(items[0].text, 'partial complete');
});

test('a replayed final event without an item ID reconciles the same turn but leaves equal answers in other turns', () => {
  let items = historyItems([{ id: 'older', items: [{ type: 'agentMessage', phase: 'final_answer', text: 'done' }] }], 'desktop');
  items = finishTimelineStream(items, null, 'done', '', 'turn', 'first', 1800000000000);
  items = finishTimelineStream(items, null, 'done', '', 'turn', 'replayed', 1800000000100);
  assert.equal(items.length, 2);
  assert.equal(items.at(-1)?.id, 'first');
});

test('different native messages with equal text and timestamp remain distinct', () => {
  const items = historyItems([{ id: 'turn', items: ['a', 'b'].map(id => ({ id, type: 'agentMessage', phase: 'commentary', text: 'same', completedAt: 1800000000000 })) }], 'desktop');
  const merged = mergeHistorySnapshot([items[0]], [items[1]], new Set(['turn']), { partial: true });
  assert.equal(merged.length, 2);
});
