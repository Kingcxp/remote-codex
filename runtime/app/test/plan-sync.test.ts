import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { mapTurns } from '../src/connector/app-server-history.js';
import { desktopHistorySnapshot } from '../src/connector/desktop-history.js';
import { historyMessageFromRow } from '../src/connector/message-history.js';
import { internals, readRolloutTail } from '../src/connector/rollout-tail.js';
import { proposedPlanText } from '../src/shared/proposed-plan.js';
import { compactReasoningTimeline, historyFingerprint, historyItems, mergeHistorySnapshot, updatePlanTimeline } from '../web/src/history-utils.js';
import type { TimelineItem } from '../web/src/history-utils.js';
import { friendlyError } from '../web/src/app-utils.js';

const body = '# 完整计划\n\n' + '检查现有配置并验证结果。\n'.repeat(1800);
const wrapped = `<proposed_plan>\n${body}\n</proposed_plan>`;
const native = () => ({ id: 'thread', threadRuntimeStatus: { type: 'active' }, requests: [],
  turns: [{ turnId: 'turn', status: 'inProgress', turnStartedAtMs: Date.now() - 5000,
    completedItemIds: [] as string[], items: [{ id: 'plan', type: 'plan', text: body }] }] });

test('an unsupported Desktop protocol explains the required bridge update instead of suggesting reopening the chat', () => {
  assert.match(friendlyError('desktop_state_protocol_unsupported'), /状态协议已更新|newer state protocol/);
});

test('native plan drafts survive full history mapping, refresh, reasoning cleanup and completion metadata', () => {
  const state = native();
  const draft = desktopHistorySnapshot(state)!;
  assert.equal(draft.activityKind, 'writingPlan');
  assert.equal(draft.turn.items[0].text, body.trim());
  const items = historyItems([draft.turn], 'desktop');
  assert.equal(items[0].planStatus, 'draft');
  assert.deepEqual(compactReasoningTimeline(items, true, 'turn'), items);
  state.turns[0].completedItemIds = ['plan'];
  const complete = desktopHistorySnapshot(state)!;
  const refreshed = historyItems([complete.turn], 'desktop');
  assert.equal(refreshed[0].planStatus, 'complete');
  assert.equal(refreshed[0].text, body.trim());
  assert.notEqual(historyFingerprint([draft.turn]), historyFingerprint([complete.turn]));
  const merged = mergeHistorySnapshot(items, refreshed, new Set(['turn']), { partial: true });
  assert.equal(merged.length, 1);
  assert.equal(merged[0].planStatus, 'complete');
  state.threadRuntimeStatus.type = 'idle';
  state.turns[0].status = 'completed';
  assert.equal(historyItems([desktopHistorySnapshot(state)!.turn])[0].planStatus, 'complete');
});

test('a pending native question overrides stale planning activity and exposes no raw request data in history', () => {
  const state: any = native();
  state.requests = [{ id: 1, method: 'item/tool/requestUserInput', privateMetadata: 'private request data' }];
  const history = desktopHistorySnapshot(state)!;
  assert.equal(history.activityKind, 'waiting');
  assert.equal(history.activityDetail, '');
  assert.ok(!JSON.stringify(history).includes('private request data'));
});

test('streamed plans hydrate once, replace drafts with canonical final text, and ignore late deltas', () => {
  let items: TimelineItem[] = [];
  items = updatePlanTimeline(items, { itemId: 'p', turnId: 't', delta: '# Draft', offset: 0 });
  items = updatePlanTimeline(items, { itemId: 'p', turnId: 't', delta: '\nFirst step', offset: 7 });
  assert.equal(items[0].planStatus, 'draft');
  const snapshot = historyItems(mapTurns([{ id: 't', status: 'inProgress', items: [
    { id: 'p', type: 'plan', text: '# Draft\nFirst step' },
  ] }]), 'desktop');
  assert.equal(snapshot[0].planStatus, 'draft', 'app-server plan items omit individual status while streaming');
  items = mergeHistorySnapshot(items, snapshot, new Set(['t']), { partial: true });
  items = updatePlanTimeline(items, { itemId: 'p', turnId: 't', delta: '\nFirst step', offset: 7 });
  assert.equal(items.length, 1);
  assert.equal(items[0].text, '# Draft\nFirst step');
  items = updatePlanTimeline(items, { itemId: 'p', turnId: 't', text: '# Final\nA revised step', completed: true });
  assert.equal(items[0].text, '# Final\nA revised step');
  assert.equal(items[0].planStatus, 'complete');
  items = mergeHistorySnapshot(items, snapshot, new Set(['t']), { partial: true });
  assert.equal(items[0].planStatus, 'complete', 'a late active snapshot cannot reopen a completed plan');
  assert.equal(items[0].text, '# Final\nA revised step');
  assert.deepEqual(updatePlanTimeline(items, { itemId: 'p', turnId: 't', delta: 'stale', offset: 0 }), items);
  items = updatePlanTimeline(items, { itemId: 'p', turnId: 'next', delta: 'A new plan', offset: 0 });
  assert.equal(items.length, 2, 'another turn cannot overwrite a previous plan with the same item id');
});

test('wrapped plans map across old and new history formats without truncating or losing search content', () => {
  for (const item of [{ id: 'p', type: 'plan', text: body }, { id: 'p', type: 'agentMessage', text: wrapped, phase: 'commentary' }]) {
    const timeline = historyItems(mapTurns([{ id: 't', status: 'completed', items: [item] }]));
    assert.equal(timeline[0].planStatus, 'complete');
    assert.equal(timeline[0].text, body.trim());
  }
  for (const row of [
    { type: 'response_item', payload: { type: 'plan', text: body } },
    { type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: wrapped }] } },
    { type: 'event_msg', payload: { type: 'item_completed', item: { type: 'plan', text: body } } },
    { type: 'event_msg', payload: { type: 'agent_message', phase: 'commentary', message: wrapped } },
  ]) {
    assert.equal(internals.mapRolloutRows([row])[0].type, 'plan');
    assert.equal(internals.mapRolloutRows([row])[0].text?.trim(), body.trim());
    assert.equal(historyMessageFromRow(row, 'thread', 'turn', 0)?.text.trim(), body.trim());
    assert.equal(historyMessageFromRow(row, 'thread', 'turn', 0)?.phase, 'final_answer');
  }
});

test('plan wrappers in user messages or quoted examples remain ordinary literal content', () => {
  for (const value of [`示例：${wrapped}`, `\`\`\`xml\n${wrapped}\n\`\`\``, `${wrapped}\n保留说明`, '<proposed_plan>未完成']) {
    assert.equal(proposedPlanText(value), null);
  }
  const user = historyItems(mapTurns([{ id: 't', items: [{ type: 'userMessage', text: wrapped }] }]))[0];
  assert.equal(user.kind, 'user');
  assert.equal(user.planStatus, undefined);
  assert.equal(user.text, wrapped);
});

test('completed plan-only rollouts remain visible after reconnect and task completion fallback is deduplicated', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'codex-plan-sync-'));
  const filePath = join(directory, 'rollout.jsonl');
  try {
    await writeFile(filePath, [
      { type: 'event_msg', payload: { type: 'task_started', turn_id: 't' } },
      { type: 'event_msg', payload: { type: 'user_message', message: '写一个计划' } },
      { type: 'response_item', payload: { type: 'message', role: 'assistant', phase: 'final_answer', content: [{ type: 'output_text', text: wrapped }] } },
      { type: 'event_msg', payload: { type: 'task_complete', turn_id: 't', last_agent_message: wrapped } },
    ].map(row => JSON.stringify({ timestamp: new Date().toISOString(), ...row })).join('\n') + '\n');
    const page = await readRolloutTail({ filePath, threadId: 'thread', maxBytes: 128 * 1024 });
    const plans = historyItems(page.turns, page.source).filter(item => item.planStatus);
    assert.equal(plans.length, 1);
    assert.equal(plans[0].text, body.trim());
    assert.equal(plans[0].planStatus, 'complete');
  } finally {
    internals.rolloutCache.delete(filePath);
    await rm(directory, { recursive: true, force: true });
  }
});
