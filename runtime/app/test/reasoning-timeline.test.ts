import assert from 'node:assert/strict';
import test from 'node:test';
import {
  appendTimelineStream, finishTimelineStream, compactReasoningTimeline, historyItems, mergeHistorySnapshot, prependHistoryPage,
  type TimelineItem,
} from '../web/src/history-utils.js';

const reasoning = (id: string, turn = 'active'): TimelineItem => ({
  id, kind: 'progress', progressType: 'reasoning', historyTurnId: turn, text: `摘要 ${id}`,
});

test('late reasoning after a final reply cannot resurrect the live thinking card', () => {
  const answer: TimelineItem = { id: 'final', kind: 'assistant', text: '已经完成', historyTurnId: 'active' };
  assert.deepEqual(compactReasoningTimeline([prompt, answer, reasoning('late')], true, 'active'), [prompt, answer]);
});

test('stream items, native history and final phase correction preserve one message identity', () => {
  const stream = { id: 'stream', kind: 'progress' as const, sourceItemId: 'reply', historyTurnId: 'active', progressType: 'commentary' as const };
  let items = appendTimelineStream([prompt, reasoning('think')], stream, '答案是 ', 0);
  const native = historyItems([{ id: 'active', status: 'inProgress', items: [
    { id: 'reply', type: 'agentMessage', phase: 'final_answer', text: '答案是 42' },
  ] }], 'desktop');
  items = mergeHistorySnapshot(items, native, new Set(['active']), { partial: true });
  items = appendTimelineStream(items, stream, '42', 4);
  items = finishTimelineStream(items, stream, '答案是 42', 'reply', 'active', 'new-final', 1000);
  assert.equal(items.filter(item => item.sourceItemId === 'reply').length, 1);
  assert.equal(items.find(item => item.sourceItemId === 'reply')?.text, '答案是 42');
  assert.equal(items.find(item => item.sourceItemId === 'reply')?.kind, 'assistant');
  assert.equal(compactReasoningTimeline(items, true, 'active').some(item => item.progressType === 'reasoning'), false);
});

test('separate commentary items never concatenate and same-source final replaces its streamed draft', () => {
  const first = { id: 'one', kind: 'progress' as const, sourceItemId: 'comment', historyTurnId: 'active', progressType: 'commentary' as const };
  const second = { ...first, id: 'two', sourceItemId: 'answer' };
  let items = appendTimelineStream([prompt], first, '正在检查', 0);
  items = appendTimelineStream(items, second, '结果', 0);
  items = finishTimelineStream(items, second, '结果完整', 'answer', 'active', 'final-id', 1000);
  assert.deepEqual(items.map(item => [item.kind, item.text]), [['user', '修复问题'], ['progress', '正在检查'], ['assistant', '结果完整']]);
  items = mergeHistorySnapshot(items, historyItems([{ id: 'active', status: 'completed', items: [
    { id: 'comment', type: 'agentMessage', phase: 'commentary', text: '正在检查' },
    { id: 'answer', type: 'agentMessage', phase: 'final_answer', text: '结果完整' },
  ] }], 'desktop'), new Set(['active']), { partial: true });
  assert.equal(items.filter(item => item.text === '结果完整').length, 1);
  assert.equal(items.filter(item => item.text === '正在检查').length, 1);
});

test('stream offsets are idempotent when a snapshot already contains the received text', () => {
  const stream = { id: 'stream', kind: 'assistant' as const, sourceItemId: 'answer', historyTurnId: 'active', progressType: 'commentary' as const };
  const history = [{ id: 'history', kind: 'assistant' as const, text: 'Hello world', sourceItemId: 'answer', historyTurnId: 'active' }];
  const items = appendTimelineStream(history, stream, 'world', 6);
  assert.equal(items.length, 1);
  assert.equal(items[0].text, 'Hello world');
  assert.equal(items[0].id, 'history');
});

test('native-to-rollout handoff matches visible commentary without merging it into reasoning or final output', () => {
  const native = historyItems([{ id: 'active', status: 'completed', items: [
    { id: 'c', type: 'agentMessage', phase: 'commentary', text: '验证中', completedAt: 1800000000000 },
    { id: 'f', type: 'agentMessage', phase: 'final_answer', text: '验证完成', completedAt: 1800000001000 },
  ] }], 'desktop');
  const rollout = historyItems([{ id: 'active', status: 'completed', items: [
    { type: 'agentMessage', phase: 'commentary', text: '验证中', completedAt: 1800000000200 },
    { type: 'agentMessage', phase: 'final_answer', text: '验证完成', completedAt: 1800000001200 },
    { type: 'reasoning', text: '迟到的摘要', completedAt: 1800000001500 },
  ] }], 'rolloutPage');
  const visible = compactReasoningTimeline(mergeHistorySnapshot(native, rollout, new Set(['active']), { partial: true }), true, 'active');
  assert.deepEqual(visible.map(item => item.text), ['验证中', '验证完成']);
  assert.equal(visible[0].id, native[0].id);
});

test('native to coalesced rollout and back does not retain both whole cards and their parts', () => {
  const entries = ['第一条进度', '第二条进度', '第三条进度'].map((text, i) => ({
    id: `c${i}`, type: 'agentMessage', phase: 'commentary', text, completedAt: 1800000000000 + i * 1000,
  }));
  const native = historyItems([{ id: 'active', items: entries }], 'desktop');
  const rollout = historyItems([{ id: 'active', items: entries.map(({ id, ...item }) => ({ ...item, completedAt: item.completedAt + 250 })) }], 'rolloutPage');
  const combined = mergeHistorySnapshot(native, rollout, new Set(['active']), { partial: true });
  assert.equal(combined.length, 1);
  const restored = mergeHistorySnapshot(combined, native, new Set(['active']), { partial: true });
  assert.deepEqual(restored.map(item => item.text), entries.map(item => item.text));
});
const prompt: TimelineItem = { id: 'u', kind: 'user', text: '修复问题', historyTurnId: 'active' };

test('thousands of completed/active summaries occupy only one live reasoning card', () => {
  const old = Array.from({ length: 1500 }, (_, i) => reasoning(`old-${i}`, 'previous'));
  const current = Array.from({ length: 500 }, (_, i) => reasoning(`current-${i}`));
  const commentary: TimelineItem = { id: 'c', kind: 'progress', progressType: 'commentary', text: '测试正在运行', historyTurnId: 'active' };
  const raw = [...old, prompt, ...current, commentary];
  const visible = compactReasoningTimeline(raw, true, 'active');
  assert.deepEqual(visible.map(item => item.id), ['u', 'current-499', 'c']);
  assert.equal(visible[1], current.at(-1));
  assert.equal(raw.length, 2002, 'projection never erases the source history');
  assert.deepEqual(compactReasoningTimeline([...raw, reasoning('new')], true, 'active').map(item => item.id), ['u', 'c', 'new']);
});

test('completion, stop, and a final reply arriving ahead of idle remove reasoning placeholders', () => {
  const pending = [prompt, reasoning('thinking')];
  assert.deepEqual(compactReasoningTimeline(pending, false, 'active'), [prompt]);
  const answer: TimelineItem = { id: 'answer', kind: 'assistant', text: '修复完成', historyTurnId: 'active' };
  assert.deepEqual(compactReasoningTimeline([...pending, answer], true, 'active'), [prompt, answer]);
  assert.deepEqual(compactReasoningTimeline([...pending, answer], false), [prompt, answer]);
});

test('partial snapshots, replays, and prepended history cannot resurrect old cards', () => {
  const current = historyItems([{ id: 'active', items: [
    { id: 'u', type: 'userMessage', text: '修复问题' },
    { id: 'r1', type: 'reasoning', text: '旧摘要' },
    { id: 'r2', type: 'reasoning', text: '新摘要' },
  ] }], 'appServer');
  const latest = historyItems([{ id: 'active', items: [{ id: 'r2', type: 'reasoning', text: '新摘要更新' }] }], 'appServer');
  const merged = mergeHistorySnapshot(current, latest, new Set(['active']), { partial: true });
  const withOlder = prependHistoryPage([reasoning('ancient', 'previous')], merged);
  const visible = compactReasoningTimeline(withOlder, true, 'active');
  assert.equal(visible.filter(item => item.progressType === 'reasoning').length, 1);
  assert.equal(visible.at(-1)?.text, '新摘要更新');
  assert.equal(compactReasoningTimeline(withOlder, false).some(item => item.progressType === 'reasoning'), false);
});

test('coalesced legacy summaries show just the latest whole summary without splitting Markdown', () => {
  const markdown = '最新说明\n\n```ts\nconst ready = true;\n```';
  const legacy = { ...reasoning('legacy'), text: `旧摘要\n\n${markdown}`,
    progressParts: [{ text: '旧摘要', completedAt: 10 }, { text: markdown, completedAt: 20 }] };
  const visible = compactReasoningTimeline([prompt, legacy], true);
  assert.equal(visible[1].text, markdown);
  assert.equal(visible[1].completedAt, 20);
  assert.equal(legacy.progressParts.length, 2);
});

test('new turns, pending prompts and transient streams never reuse an earlier turn summary', () => {
  assert.deepEqual(compactReasoningTimeline([prompt, reasoning('old', 'previous')], true, 'active'), [prompt]);
  const newPrompt: TimelineItem = { id: 'new-u', kind: 'user', text: '下一步', transient: true };
  assert.deepEqual(compactReasoningTimeline([prompt, reasoning('old'), newPrompt], true), [prompt, newPrompt]);
  const stream = { ...reasoning('stream'), historyTurnId: undefined, transient: true };
  assert.equal(compactReasoningTimeline([newPrompt, stream], true, 'new-turn').at(-1), stream);
});

test('questions, visible commentary, quoted reasoning text and artifacts remain visible', () => {
  const items: TimelineItem[] = [prompt,
    { id: 'text', kind: 'assistant', text: '“思考摘要”是页面上的标题。', historyTurnId: 'previous' },
    { id: 'c', kind: 'progress', progressType: 'commentary', text: '正在验证' },
    { ...reasoning('image'), attachment: { path: '/image.png', name: 'image' } },
    { ...reasoning('visual'), visualization: { path: '/chart.html', name: 'chart', source: 'visualize' } },
    { id: 'question', kind: 'assistant', text: '选择分支', questions: [{ id: 'q', title: '选择分支', options: [] }] },
    reasoning('live'),
  ];
  assert.equal(compactReasoningTimeline(items, true, 'active').at(-1)?.id, 'live');
  assert.deepEqual(compactReasoningTimeline(items, false), items.slice(0, -1));
});

test('pagination preserves reasoning/commentary boundaries and identified native items', () => {
  const older: TimelineItem[] = [{ ...reasoning('r'), completedAt: 1800000000010 }];
  const comment: TimelineItem = { id: 'c', kind: 'progress', progressType: 'commentary', text: '正常进度', historyTurnId: 'active', completedAt: 1800000000020 };
  assert.deepEqual(prependHistoryPage(older, [comment]).map(item => item.text), ['摘要 r', '正常进度']);
  const identified = [{ ...reasoning('r1'), sourceItemId: 'r1' }, { ...reasoning('r2'), sourceItemId: 'r2' }];
  assert.deepEqual(prependHistoryPage([identified[0]], [identified[1]]).map(item => item.id), ['r1', 'r2']);
  const duplicateText = { ...comment, text: older[0].text, completedAt: older[0].completedAt };
  assert.equal(prependHistoryPage(older, [duplicateText]).length, 2, 'same text/time does not erase a different message type');
});
