import assert from 'node:assert/strict';
import test from 'node:test';
import { CodexDesktopClient } from '../src/connector/codex-desktop.js';
import { NativeRequestError } from '../src/connector/desktop-native-pipe.js';

function fixture() {
  const client = new CodexDesktopClient();
  const calls: any[] = [];
  let status = 'idle', latest = 'old', turnStatus = 'completed', unknown = false;
  client.userInput.startQueued = client.userInput.steerQueued = async () => { throw new Error('desktop_input_unavailable'); };
  client.controls.snapshot = async () => { throw new Error('desktop_input_unavailable'); };
  client.callTool = async call => {
    calls.push(call);
    if (call.tool === 'read_thread') return { success: true, contentItems: [{ text: JSON.stringify({
      thread: { id: 'target', status: { type: status, activeFlags: [] } },
      turns: call.arguments.includeTurns ? [{ id: latest, status: turnStatus, items: [
        { id: 'answer', type: 'agentMessage', phase: 'final_answer', text: 'preview' },
      ] }] : [],
    }) }] };
    if (unknown) throw new NativeRequestError('lost acknowledgement', true);
    return { success: true, contentItems: [{ text: JSON.stringify({ threadId: 'target' }) }] };
  };
  return { client, calls, state: (next: { status?: string; latest?: string; turnStatus?: string; unknown?: boolean }) => {
    status = next.status ?? status; latest = next.latest ?? latest; turnStatus = next.turnStatus ?? turnStatus; unknown = next.unknown ?? unknown;
  } };
}
const input = { threadId: 'target', text: 'user input', requestId: 'request' };

test('missing legacy input uses the selected task app tools and waits for the next completed turn', async () => {
  const { client, calls, state } = fixture();
  try {
    assert.deepEqual(await client.queueState('target'), { ready: true, previousTurnComplete: true });
    assert.equal(calls[0].arguments.includeTurns, false, 'idle check never loads a large conversation');
    const sent = await client.deliverMessage(input, true);
    assert.match(sent.turnId, /^app-tools-after:/);
    assert.equal((await client.queueState('target', sent.turnId)).previousTurnComplete, false);
    state({ status: 'active', latest: 'new', turnStatus: 'inProgress' });
    assert.equal((await client.queueState('target', sent.turnId)).ready, false);
    state({ status: 'idle', turnStatus: 'completed' });
    assert.deepEqual(await client.queueState('target', sent.turnId), { ready: true, previousTurnComplete: true });
    const sends = calls.filter(c => c.tool === 'send_message_to_thread');
    assert.equal(sends.length, 1);
    assert.equal(sends[0].callerThreadId, 'target');
    assert.deepEqual(sends[0].arguments, { threadId: 'target', prompt: 'user input' });
    assert.ok(calls.filter(c => c.arguments.includeTurns).every(c => c.arguments.turnLimit === 1));
  } finally { client.close(); }
});

test('an active task keeps queued input but explicit Guide can send, and lost acknowledgements never fall back', async () => {
  const { client, calls, state } = fixture();
  try {
    state({ status: 'active', turnStatus: 'inProgress' });
    await assert.rejects(client.deliverMessage(input, true), /desktop_queue_busy/);
    assert.equal(calls.some(c => c.tool === 'send_message_to_thread'), false);
    assert.equal((await client.deliverMessage(input)).turnId, 'old');
    state({ unknown: true });
    await assert.rejects(client.deliverMessage(input), /desktop_delivery_unknown/);
    const count = calls.length;
    client.userInput.steerQueued = async () => { throw new Error('desktop_delivery_unknown'); };
    await assert.rejects(client.deliverMessage(input), /desktop_delivery_unknown/);
    assert.equal(calls.length, count);
  } finally { client.close(); }
});

test('plain host errors are read failures and completed bounded previews do not replace full history', async () => {
  const { client } = fixture();
  try {
    client.controls.readHistory = async () => { throw new Error('desktop_input_unavailable'); };
    assert.equal(await client.readHistory('target'), null);
    client.callTool = async () => ({ success: false, contentItems: [{ text: 'Tool response exceeds the size limit.' }] });
    await assert.rejects(client.queueState('target'), /desktop_thread_read_failed/);
  } finally { client.close(); }
});

test('injected lifecycle reader keeps huge histories out of readiness and delivery calls', async () => {
  const { client, calls, state } = fixture();
  const reader = new CodexDesktopClient({ readLatestTurn: async () => ({ id: 'bounded-lifecycle', status: 'completed' }) });
  reader.userInput.startQueued = async () => { throw new Error('desktop_input_unavailable'); };
  reader.controls.snapshot = async () => { throw new Error('desktop_input_unavailable'); };
  reader.callTool = client.callTool;
  try {
    const result = await reader.deliverMessage(input, true);
    state({ latest: 'huge-turn-not-loaded' });
    assert.equal((await reader.queueState('target', result.turnId)).previousTurnComplete, false);
    assert.ok(calls.filter(call => call.tool === 'read_thread').every(call => call.arguments.includeTurns === false));
  } finally { reader.close(); client.close(); }
});
