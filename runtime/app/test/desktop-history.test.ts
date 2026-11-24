import assert from 'node:assert/strict';
import test from 'node:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { desktopHistorySnapshot, mergeDesktopHistoryPage } from '../src/connector/desktop-history.js';
import { historyItems, mergeHistorySnapshot } from '../web/src/history-utils.js';
import { LiveActivityStatus } from '../web/src/live-activity.js';

const start = 1_794_294_050_000;
function fixture() {
  return { id: 'task', threadRuntimeStatus: { type: 'active' }, turns: [],
    turnHistory: { history: { entitiesByKey: { current: {
      turnId: 'current', status: 'inProgress', turnStartedAtMs: start,
      params: { clientUserMessageId: 'input', input: [{ type: 'text', text: '刚发送的消息' }], providerSecrets: 'private' },
      items: [{ type: 'contextCompaction', id: 'compact', startedAtMs: start + 500, completed: false }],
    } } } } };
}

test('owner input is visible during pre-turn compaction before it exists on disk', () => {
  const state = fixture(), original = structuredClone(state);
  const snapshot = desktopHistorySnapshot(state)!;
  assert.equal(snapshot.compactionStartedAt, start + 500);
  assert.equal(snapshot.activityKind, 'compacting');
  assert.equal(snapshot.activityStartedAt, start);
  assert.equal(snapshot.turn.items[0].text, '刚发送的消息');
  assert.equal(snapshot.turn.items[0].id, 'input');
  assert.equal(snapshot.turn.status, 'inProgress');
  assert.deepEqual(state, original, 'reading never mutates the host');
  assert.ok(!JSON.stringify(snapshot).includes('providerSecrets'));
});

test('steering input received during compaction cannot hide the accepted original input', () => {
  const state: any = fixture();
  state.turnHistory.history.entitiesByKey.current.items.push({ type: 'userMessage', id: 'steer', clientId: 'different-client',
    content: [{ type: 'text', text: '立即引导的新内容' }], completedAtMs: start + 1000 });
  assert.deepEqual(desktopHistorySnapshot(state)?.turn.items.filter(item => item.type === 'userMessage').map(item => item.text),
    ['刚发送的消息', '立即引导的新内容']);
});

test('persisted user input hydrates the same card once and streamed reasoning stays separate', () => {
  const state: any = fixture();
  const before = desktopHistorySnapshot(state)!;
  state.turnHistory.history.entitiesByKey.current.items = [
    { type: 'contextCompaction', id: 'compact', startedAtMs: start + 500, completedAtMs: start + 120_000, completed: true },
    { type: 'userMessage', id: 'host-user-id', clientId: 'input', content: [{ type: 'text', text: '刚发送的消息' }], completedAtMs: start + 120_001 },
    { type: 'reasoning', id: 'reason', summary: ['正在检查'], content: ['private reasoning'], encrypted_content: 'encrypted secret', startedAtMs: start + 121_000 },
    { type: 'agentMessage', id: 'comment', phase: 'commentary', text: '正常进度', startedAtMs: start + 122_000 },
  ];
  const after = desktopHistorySnapshot(state)!;
  assert.equal(after.compactionStartedAt, null);
  assert.equal(after.activityKind, 'responding');
  const first = historyItems([before.turn], 'desktop');
  const merged = mergeHistorySnapshot(first, historyItems([after.turn], 'desktop'), new Set(['current']), { partial: true });
  assert.equal(merged.filter(i => i.kind === 'user').length, 1);
  assert.equal(merged[0].id, first[0].id);
  assert.equal(merged.find(i => i.progressType === 'reasoning')?.text, '正在检查');
  assert.ok(!JSON.stringify(after).includes('private reasoning'));
  assert.ok(!JSON.stringify(after).includes('encrypted secret'));
  assert.equal(after.activityUpdatedAt, start + 122_000);
});

test('native terminal state clears compaction and stale disk activity without losing final output', () => {
  const state: any = fixture();
  state.threadRuntimeStatus.type = 'idle';
  const turn = state.turnHistory.history.entitiesByKey.current;
  turn.status = 'completed';
  turn.items.push({ type: 'agentMessage', id: 'answer', phase: 'final_answer', text: '完成', completedAtMs: start + 150_000 });
  const snapshot = desktopHistorySnapshot(state)!;
  const page = mergeDesktopHistoryPage({ threadId: 'task', source: 'rolloutTail', turns: [{ id: 'tail:task', status: 'inProgress', items: [] }] }, snapshot);
  assert.equal(page.turns[0].status, 'completed');
  assert.equal(page.activityKind, '');
  assert.equal(page.compactionStartedAt, null);
  assert.equal(page.turns[0].items.at(-1).text, '完成');
  assert.equal(page.turns.length, 1);
});

test('partial rollout overlay preserves earlier turns, pagination, questions and context usage', () => {
  const snapshot = desktopHistorySnapshot(fixture())!;
  const older = { type: 'agentMessage', turnId: 'older', text: '旧回答' };
  const page = { threadId: 'task', source: 'rolloutPage', activityStartedAt: start, nextCursor: 'older-page', questionReplies: [{ answer: 'yes' }],
    contextUsage: { tokens: 1000 }, turns: [{ id: 'rollout:task', status: 'inProgress', items: [older, { type: 'userMessage', turnId: 'current', text: '旧占位' }] }] };
  const merged = mergeDesktopHistoryPage(page, snapshot);
  assert.equal(merged.turns[0], snapshot.turn);
  assert.deepEqual(merged.turns[1].items, [older]);
  assert.equal(merged.nextCursor, 'older-page');
  assert.equal(merged.questionReplies, page.questionReplies);
  assert.equal(merged.contextUsage, page.contextUsage);
});

test('snapshots cannot overwrite another task, a newer turn or already completed persisted output', () => {
  const snapshot = desktopHistorySnapshot(fixture())!;
  for (const page of [
    { threadId: 'other', turns: [] },
    { threadId: 'task', activityStartedAt: start + 1000, turns: [{ id: 'newer' }] },
    { threadId: 'task', turns: [{ id: 'current', status: 'completed', completedAt: (start + 1000) / 1000 }] },
  ]) assert.equal(mergeDesktopHistoryPage(page, snapshot), page);
  const stale = { threadId: 'task', turns: [{ id: 'current', status: 'interrupted', completedAt: null, items: [] }] };
  assert.equal(mergeDesktopHistoryPage(stale, snapshot).turns[0].status, 'inProgress', 'empty disk placeholder is not a real cancellation');
  assert.equal(desktopHistorySnapshot({ id: 'task', threadRuntimeStatus: { type: 'unknown' } }), null);
});

test('only the active native turn supplies status, including a turn with no work items yet', () => {
  const state: any = fixture();
  state.turns.push({ turnId: 'old', status: 'inProgress', turnStartedAtMs: start - 1000, items: [] });
  state.turnHistory.history.entitiesByKey.current.items = [];
  const snapshot = desktopHistorySnapshot(state)!;
  assert.equal(snapshot.activityId, 'current');
  assert.equal(snapshot.activityKind, 'starting');
  assert.equal(snapshot.turn.items[0].text, '刚发送的消息');
});

test('progress status shows compaction and time without new progress instead of endless startup', () => {
  const now = Date.now();
  const render = (kind: 'compacting' | 'starting') => renderToStaticMarkup(createElement(LiveActivityStatus, {
    kind, purpose: '', detail: '', progress: {}, startedAt: now - 180_000, updatedAt: now - 130_000,
  }));
  assert.match(render('compacting'), /正在整理上下文/);
  assert.match(render('compacting'), /没有新进度/);
  assert.doesNotMatch(render('starting'), /正在启动/);
  assert.match(render('starting'), /正在等待/);
});
