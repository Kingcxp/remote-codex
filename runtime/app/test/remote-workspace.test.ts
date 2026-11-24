import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, writeFile, rm, appendFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { readMessageHistory } from '../src/connector/message-history.js';
import { CodexAppServer } from '../src/connector/codex-app-server.js';
import { historyItems, mergeHistorySnapshot } from '../web/src/history-utils.js';
import { mapTurns } from '../src/connector/app-server-history.js';

async function fixture(t: any, rows: any[]) {
  const directory = await mkdtemp(join(tmpdir(), 'codex-workspace-test-'));
  t.after(async () => {
    assert.ok(resolve(directory).startsWith(resolve(tmpdir())) && /codex-workspace-test-/.test(directory));
    await rm(directory, { recursive: true, force: true });
  });
  const path = join(directory, 'rollout.jsonl');
  await writeFile(path, rows.map(row => JSON.stringify(row)).join('\n') + '\n');
  return path;
}
const row = (type: string, text: string, n: number, extra = {}) => ({ type: 'event_msg', timestamp: new Date(1_800_000_000_000 + n * 1000).toISOString(),
  payload: { type, message: text, turn_id: 't' + n, ...extra } });

test('byte-offset history reads old user messages through compaction and remains stable while host appends', async t => {
  const first = '第一条：' + '中文😀'.repeat(40_000);
  const path = await fixture(t, [row('user_message', first, 1), { type: 'compacted', payload: { message: 'summary' } },
    row('agent_message', '最终答案', 2, { phase: 'final_answer' }), row('user_message', '最近消息', 3)]);
  const page = await readMessageHistory(path, 'chat', { role: 'user', limit: 1 });
  assert.equal(page.messages[0].text, '最近消息'); assert.ok(page.nextCursor);
  await appendFile(path, JSON.stringify(row('user_message', '追加消息', 4)) + '\n');
  const old = await readMessageHistory(path, 'chat', { role: 'user', cursor: page.nextCursor });
  assert.equal(old.messages.length, 1); assert.equal(old.messages[0].text, first); assert.equal(old.nextCursor, null);
  assert.notEqual(old.messages[0].id, page.messages[0].id);
});

test('literal search finds text beyond the old truncation boundary and sparse pages keep a continuation cursor', async t => {
  const path = await fixture(t, [row('user_message', 'old [literal.*] match', 1),
    row('user_message', 'a'.repeat(550_000) + '目标关键词', 2),
    ...Array.from({ length: 12 }, (_, i) => ({ type: 'response_item', payload: { type: 'function_call_output', output: 'x'.repeat(50_000) }, timestamp: String(i) }))]);
  const sparse = await readMessageHistory(path, 'chat', { query: '目标关键词', scanBytes: 100_000 });
  assert.equal(sparse.messages.length, 0); assert.ok(sparse.nextCursor);
  const found = await readMessageHistory(path, 'chat', { cursor: sparse.nextCursor, query: '目标关键词' });
  assert.equal(found.messages.length, 1); assert.ok(found.messages[0].text.includes('目标关键词')); assert.equal(found.messages[0].truncated, true);
  const literal = await readMessageHistory(path, 'chat', { query: '[literal.*]' });
  assert.equal(literal.messages.length, 1);
});

test('history deduplicates event/response copies but preserves deliberate identical user messages', async t => {
  const path = await fixture(t, [row('user_message', 'repeat', 1),
    { type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'repeat' }] } },
    row('task_started', '', 2), row('user_message', 'repeat', 2)]);
  const page = await readMessageHistory(path, 'chat');
  assert.equal(page.messages.length, 2); assert.equal(page.messages[0].text, page.messages[1].text);
  const first = await readMessageHistory(path, 'chat', { limit: 1 });
  const second = await readMessageHistory(path, 'chat', { limit: 1, cursor: first.nextCursor });
  assert.equal(second.messages.length, 1);
  const last = await readMessageHistory(path, 'chat', { limit: 1, cursor: second.nextCursor });
  assert.equal(last.messages.length, 0, 'a duplicated event at a page boundary is not another user message');
});

test('historical goal wakeups do not occupy user history or search results, while actual output remains searchable', async t => {
  const internal = '<codex_internal_context source="goal">Continue working toward the active thread goal.\n<objective>Internal repetition</objective></codex_internal_context>';
  const path = await fixture(t, [row('user_message', 'Real user instruction', 1),
    ...Array.from({ length: 5 }, () => ({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: internal }] } })),
    row('agent_message', 'Actual goal output', 2, { phase: 'final_answer' })]);
  const page = await readMessageHistory(path, 'chat');
  assert.deepEqual(page.messages.map(message => message.text), ['Actual goal output', 'Real user instruction']);
  assert.equal((await readMessageHistory(path, 'chat', { role: 'user' })).messages.length, 1);
  assert.equal((await readMessageHistory(path, 'chat', { query: 'Internal repetition' })).messages.length, 0);
  assert.equal((await readMessageHistory(path, 'chat', { query: 'Actual goal output' })).messages.length, 1);
});

test('global message search spans providers and archived chats without resuming a writer', async t => {
  const a = await fixture(t, [row('user_message', 'shared needle', 1)]);
  const b = await fixture(t, [row('agent_message', 'shared NEEDLE', 2, { phase: 'final_answer' })]);
  const codex = new CodexAppServer();
  codex.listSessions = async () => [{ id: 'a', title: 'Active', archived: false }, { id: 'b', title: 'Archived', archived: true }] as any;
  codex.sessionMetadata.set('a', { path: a, cwd: '', canAcceptDirectInput: true });
  codex.sessionMetadata.set('b', { path: b, cwd: '', canAcceptDirectInput: true });
  codex.rpcRaw = async () => assert.fail('search must never resume or mutate a Codex thread');
  const result = await codex.searchMessages({ query: 'needle', role: 'all' });
  assert.deepEqual(result.matches.map(m => m.threadId), ['a', 'b']); assert.equal(result.nextCursor, null);
  assert.equal((await codex.searchMessages({ query: 'needle', role: 'user' })).matches.length, 1);
});

test('stable item identity updates streamed text in place and keeps reasoning separate from final output', () => {
  const turns = (thinking: string, final: string) => [{ id: 't', status: 'inProgress', items: [
    { id: 'u', type: 'userMessage', text: 'same prompt' },
    { id: 'r', type: 'reasoning', text: thinking, summary: [{ text: thinking }] },
    { id: 'c', type: 'agentMessage', phase: 'commentary', text: 'Working' },
    { id: 'f', type: 'agentMessage', phase: 'final_answer', text: final },
  ] }];
  const initial = historyItems(mapTurns(turns('Thinking', 'First')), 'appServer');
  const next = historyItems(mapTurns(turns('Thinking more', 'First complete')), 'appServer');
  const merged = mergeHistorySnapshot(initial, next, new Set(['t']), { partial: true });
  assert.equal(merged.length, 4);
  assert.deepEqual(merged.map(m => m.text), ['same prompt', 'Thinking more', 'Working', 'First complete']);
  assert.deepEqual(merged.map(m => m.id), initial.map(m => m.id));
  assert.equal(merged[1].progressType, 'reasoning'); assert.equal(merged[2].progressType, 'commentary');
  assert.equal(merged[3].kind, 'assistant');
});
