import assert from 'node:assert/strict';
import test from 'node:test';
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createCipheriv, createHash, randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { MessageQueue } from '../src/connector/message-queue.js';
import { desktopQueueState } from '../src/connector/desktop-queue-state.js';

async function fixture(body: (path: string, track: (q: MessageQueue) => MessageQueue) => Promise<void>) {
  const directory = mkdtempSync(join(tmpdir(), 'codex-message-queue-'));
  const queues: MessageQueue[] = [];
  try { await body(join(directory, 'queue.enc.json'), q => (queues.push(q), q)); }
  finally {
    await Promise.all(queues.map(q => q.close()));
    if (!resolve(directory).startsWith(resolve(tmpdir()) + '\\codex-message-queue-')
      && !resolve(directory).startsWith(resolve(tmpdir()) + '/codex-message-queue-')) throw new Error('unexpected test directory');
    rmSync(directory, { recursive: true, force: true });
  }
}
const input = (text: string, threadId = 'a') => ({ threadId, text, requestId: text });
async function tick(queue: MessageQueue) { queue.wake(); await delay(20); }
const idle = async () => ({ ready: true, previousTurnComplete: true });

test('pausing an empty queue does not block the next explicit message or display a permanent pause', async () => fixture(async (path, track) => {
  const sent: string[] = [];
  const options = { path, secret: 'secret', pollMs: 100_000, readState: idle,
    deliver: async (item: { text: string }) => { sent.push(item.text); return { turnId: 'new' }; } };
  const queue = track(new MessageQueue(options));
  assert.equal((await queue.setPaused('a', true)).paused, false);
  await queue.close();
  const restored = track(new MessageQueue(options));
  restored.enqueue(input('next explicit message'), 'phone'); await tick(restored);
  assert.deepEqual(sent, ['next explicit message']);
}));

test('loading an old empty paused queue repairs the persisted state before the next submission', async () => fixture(async (path, track) => {
  const key = createHash('sha256').update('codex-remote-message-queue-v1\0').update('secret').digest();
  const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, nonce);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify({ version: 1, entries: [], receipts: [], barriers: {}, paused: { a: true } })), cipher.final()]);
  writeFileSync(path, JSON.stringify({ version: 1, nonce: nonce.toString('base64'), tag: cipher.getAuthTag().toString('base64'), ciphertext: ciphertext.toString('base64') }));
  const options = { path, secret: 'secret', pollMs: 100_000, readState: idle, deliver: async () => ({ turnId: 'next' }) };
  const queue = track(new MessageQueue(options));
  assert.equal(queue.list('a').paused, false);
  await queue.close();
  const restored = track(new MessageQueue(options));
  restored.enqueue(input('next'), 'phone'); await tick(restored);
  assert.equal(restored.list('a').entries.length, 0);
}));

test('removing or guiding the last paused message clears the pause while remaining messages stay paused', async () => fixture(async (path, track) => {
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000, readState: idle,
    deliver: async () => ({ turnId: 'unused' }), steer: async () => ({ turnId: 'guided' }) }));
  const first = queue.enqueue(input('first'), 'phone'), second = queue.enqueue(input('second'), 'phone');
  await queue.setPaused('a', true); queue.remove('a', first.queueId);
  assert.equal(queue.list('a').paused, true);
  await queue.steer('a', second.queueId);
  assert.deepEqual(queue.list('a'), { threadId: 'a', entries: [], paused: false });
  const third = queue.enqueue(input('third'), 'phone'); await queue.setPaused('a', true);
  queue.remove('a', third.queueId);
  assert.equal(queue.list('a').paused, false);
}));

test('temporary control holds block new messages in an empty queue without persisting a user pause', async () => fixture(async (path, track) => {
  const sent: string[] = [];
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000, readState: idle,
    deliver: async item => { sent.push(item.text); return { turnId: 'done' }; },
    steer: async () => assert.fail('a Guide click cannot race an in-flight control operation') }));
  const release = await queue.hold('a'), nested = await queue.hold('a');
  const { queueId } = queue.enqueue(input('during compaction'), 'phone');
  await assert.rejects(queue.steer('a', queueId), /message_queue_sending/);
  await tick(queue); assert.deepEqual(sent, []); assert.equal(queue.list('a').paused, false);
  release(); release(); await tick(queue); assert.deepEqual(sent, []);
  nested(); await tick(queue); assert.deepEqual(sent, ['during compaction']);
}));

test('Guide dispatches a chosen queued message once, preserves remaining FIFO and records its turn barrier', async () => fixture(async (path, track) => {
  const sent: string[] = []; let finish!: (value: { turnId: string }) => void;
  let complete = false;
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000,
    readState: async (_thread, previous) => ({ ready: true, previousTurnComplete: !previous || complete }),
    deliver: async item => { sent.push('start:' + item.text); return { turnId: item.text }; },
    steer: async item => { sent.push('steer:' + item.text); return new Promise(resolve => { finish = resolve; }); } }));
  queue.enqueue(input('first'), 'phone'); const chosen = queue.enqueue(input('urgent'), 'phone'); queue.enqueue(input('third'), 'arch');
  const guiding = queue.steer('a', chosen.queueId);
  const repeatedClick = queue.steer('a', chosen.queueId);
  queue.wake(); await delay(5); assert.deepEqual(sent, ['steer:urgent']);
  finish({ turnId: 'active-turn' }); await guiding;
  assert.equal((await repeatedClick).turnId, 'active-turn');
  assert.equal((await queue.steer('a', chosen.queueId)).turnId, 'active-turn');
  await tick(queue); assert.deepEqual(sent, ['steer:urgent']);
  assert.deepEqual(queue.list('a').entries.map(e => e.text), ['first', 'third']);
  complete = true; await tick(queue); assert.deepEqual(sent, ['steer:urgent', 'start:first']);
}));

test('Stop pause wins over an idle check and survives restart without discarding queued text', async () => fixture(async (path, track) => {
  let release!: (value: { ready: boolean; previousTurnComplete: boolean }) => void;
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000,
    readState: () => new Promise(resolve => { release = resolve; }), deliver: async () => assert.fail('paused read must not send') }));
  queue.enqueue(input('keep this'), 'phone'); queue.wake();
  const pausing = queue.setPaused('a', true);
  release({ ready: true, previousTurnComplete: true }); await pausing; await queue.close();
  let calls = 0;
  const restored = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000, readState: idle,
    deliver: async () => { calls++; return { turnId: 'resumed' }; } }));
  await tick(restored); assert.equal(calls, 0); assert.equal(restored.list('a').paused, true);
  assert.equal(restored.list('a').entries[0].text, 'keep this');
  await restored.setPaused('a', false); await tick(restored); assert.equal(calls, 1);
}));

test('uncertain Guide remains blocked and cannot be resent by clicking again', async () => fixture(async (path, track) => {
  let calls = 0;
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000, readState: idle, deliver: async () => assert.fail(),
    steer: async () => { calls++; throw new Error('desktop_delivery_unknown'); } }));
  const { queueId } = queue.enqueue(input('urgent'), 'phone');
  await assert.rejects(queue.steer('a', queueId), /desktop_delivery_unknown/);
  await assert.rejects(queue.steer('a', queueId), /message_queue_sending/);
  assert.equal(calls, 1); assert.equal(queue.list('a').entries[0].error, 'delivery_unknown');
}));

test('native operation receipts survive service restart and cannot execute another compaction on replay', async () => fixture(async (path, track) => {
  const options = { path, secret: 'secret', pollMs: 100_000, readState: idle, deliver: async () => ({ turnId: 'unused' }) };
  const queue = track(new MessageQueue(options)); let calls = 0;
  const payload = { action: 'session.compact', threadId: 'a' };
  await queue.runOperation('phone', 'request', payload, async () => { calls++; return { started: true }; });
  await queue.close(); const restored = track(new MessageQueue(options));
  assert.deepEqual(await restored.runOperation('phone', 'request', payload, async () => assert.fail('must not repeat')), { started: true });
  await assert.rejects(restored.runOperation('phone', 'request', { ...payload, threadId: 'b' }, async () => assert.fail()), /request_mismatch/);
  assert.equal(calls, 1);
}));

test('busy tasks keep FIFO messages on Windows; only a completed turn releases the next', async () => fixture(async (path, track) => {
  let ready = false, complete = false;
  const sent: string[] = [];
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000,
    readState: async (_id, previous) => ({ ready, previousTurnComplete: !previous || complete }),
    deliver: async i => { sent.push(i.text); return { turnId: 'turn-' + i.text }; } }));
  assert.equal(queue.enqueue(input('first'), 'phone').delivery, 'queue');
  queue.enqueue(input('second'), 'arch');
  await tick(queue); assert.deepEqual(sent, []);
  ready = true; await tick(queue); assert.deepEqual(sent, ['first']);
  await tick(queue); assert.deepEqual(sent, ['first'], 'an idle-looking snapshot cannot bypass the turn barrier');
  complete = true; await tick(queue); assert.deepEqual(sent, ['first', 'second']);
  assert.deepEqual(queue.list('a').entries, []);
}));

test('the connector drains with no browser subscription and separates conversations', async () => fixture(async (path, track) => {
  let ready = false;
  const sent: string[] = [];
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 10,
    readState: async thread => ({ ready: thread === 'b' || ready, previousTurnComplete: true }),
    deliver: async i => { sent.push(i.text); return { turnId: i.text }; } }));
  queue.enqueue(input('A'), 'phone'); queue.enqueue(input('B', 'b'), 'arch');
  await delay(60); assert.deepEqual(sent, ['B']);
  ready = true; await delay(60); assert.deepEqual(sent, ['B', 'A']);
}));

test('encrypted pending messages survive a restart and reconnects do not duplicate them', async () => fixture(async (path, track) => {
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000, readState: idle,
    deliver: async () => ({ turnId: 'turn-1' }) }));
  const receipt = queue.enqueue(input('private queued text'), 'phone');
  assert.equal(readFileSync(path, 'utf8').includes('private queued text'), false);
  assert.equal(queue.enqueue(input('private queued text'), 'phone').queueId, receipt.queueId);
  assert.equal(queue.list('a').entries.length, 1);
  assert.throws(() => queue.enqueue({ ...input('different'), requestId: 'private queued text' }, 'phone'), /request_mismatch/);
  await queue.close();
  const restored = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000, readState: idle,
    deliver: async () => ({ turnId: 'turn-1' }) }));
  assert.equal(restored.list('a').entries[0].text, 'private queued text');
  await tick(restored);
  assert.equal(restored.enqueue(input('private queued text'), 'phone').queued, false);
  assert.equal(restored.list('a').entries.length, 0);
}));

test('uncertain delivery blocks this conversation and is never automatically retried', async () => fixture(async (path, track) => {
  let calls = 0;
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000, readState: idle,
    deliver: async () => { calls++; throw new Error('desktop_delivery_unknown'); } }));
  queue.enqueue(input('A'), 'phone'); queue.enqueue(input('B'), 'phone');
  await tick(queue); await tick(queue);
  assert.equal(calls, 1); assert.equal(queue.list('a').entries[0].error, 'delivery_unknown');
  assert.equal(queue.list('a').entries[1].status, 'queued');
}));

test('a crash checkpoint marked sending is held for review after restarting', async () => fixture(async (path, track) => {
  let finish!: (value: { turnId: string }) => void;
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000, readState: idle,
    deliver: () => new Promise(resolve => { finish = resolve; }) }));
  queue.enqueue(input('A'), 'phone'); queue.wake(); await delay(10);
  const crashPath = path + '.crash'; copyFileSync(path, crashPath);
  const restored = track(new MessageQueue({ path: crashPath, secret: 'secret', pollMs: 100_000, readState: idle,
    deliver: async () => assert.fail('must not retry an in-flight crash') }));
  finish({ turnId: 'turn-1' }); await delay(10);
  await tick(restored);
  assert.equal(restored.list('a').entries[0].status, 'blocked');
  assert.equal(restored.list('a').entries[0].error, 'delivery_unknown');
}));

test('cancellation is conversation-scoped, durable and immune to a replayed enqueue', async () => fixture(async (path, track) => {
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000, readState: idle,
    deliver: async () => assert.fail() }));
  const { queueId } = queue.enqueue(input('A'), 'phone');
  assert.equal(queue.remove('b', queueId).removed, false);
  assert.equal(queue.remove('a', queueId).removed, true);
  assert.equal(queue.enqueue(input('A'), 'phone').queued, false);
  await tick(queue); assert.equal(queue.list('a').entries.length, 0);
}));

test('cancelling during the idle check cannot send a removed message', async () => fixture(async (path, track) => {
  let finish!: (value: { ready: boolean; previousTurnComplete: boolean }) => void;
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000,
    readState: () => new Promise(resolve => { finish = resolve; }), deliver: async () => assert.fail() }));
  const { queueId } = queue.enqueue(input('A'), 'phone');
  queue.wake(); await delay(10); queue.remove('a', queueId);
  finish({ ready: true, previousTurnComplete: true }); await delay(10);
  assert.equal(queue.list('a').entries.length, 0);
}));

test('unknown or disconnected Desktop state waits without dropping the message', async () => fixture(async (path, track) => {
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000,
    readState: async () => { throw new Error('offline'); }, deliver: async () => assert.fail() }));
  queue.enqueue(input('A'), 'phone'); await tick(queue);
  assert.equal(queue.list('a').entries[0].status, 'queued');
}));

test('only a pre-dispatch busy check can return a submission to the queue', async () => fixture(async (path, track) => {
  let attempts = 0;
  const queue = track(new MessageQueue({ path, secret: 'secret', pollMs: 100_000, readState: idle,
    deliver: async () => { if (!attempts++) throw new Error('desktop_queue_busy'); return { turnId: 'turn-1' }; } }));
  queue.enqueue(input('A'), 'phone'); await tick(queue);
  assert.equal(queue.list('a').entries[0].status, 'queued');
  await tick(queue); assert.equal(queue.list('a').entries.length, 0); assert.equal(attempts, 2);
}));

test('invalid encryption keys cannot silently discard or replace the existing queue', async () => fixture(async (path, track) => {
  const queue = track(new MessageQueue({ path, secret: 'secret', readState: idle, deliver: async () => assert.fail() }));
  queue.enqueue(input('A'), 'phone'); const bytes = readFileSync(path);
  assert.throws(() => new MessageQueue({ path, secret: 'other', readState: idle, deliver: async () => assert.fail() }), /storage_unreadable/);
  assert.deepEqual(readFileSync(path), bytes);
}));

test('native queue eligibility rejects pending turns, approvals, unknown and stale state', () => {
  const idleState = { threadRuntimeStatus: { type: 'idle' }, turns: [{ turnId: 'old', status: 'completed' }] };
  assert.deepEqual(desktopQueueState(idleState, 'old'), { ready: true, previousTurnComplete: true });
  assert.equal(desktopQueueState(idleState, 'missing').previousTurnComplete, false);
  for (const patch of [{ threadRuntimeStatus: { type: 'active' } }, { threadRuntimeStatus: { type: 'unknown' } },
    { requests: [{}] }, { unconfirmedTurnSubmissions: [{}] }, { turns: [{ status: 'inProgress' }] },
    { threadGoal: { status: 'active' } }]) assert.equal(desktopQueueState({ ...idleState, ...patch }).ready, false);
  assert.equal(desktopQueueState({ threadRuntimeStatus: { type: 'idle' }, turnHistory: { history: { entitiesByKey: {
    entity: { turnId: 'canonical', status: 'completed' },
  } } } }, 'canonical').previousTurnComplete, true);
});
