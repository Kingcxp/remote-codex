import assert from 'node:assert/strict';
import test from 'node:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { DesktopQueuePanel, MessageQueuePanel } from '../web/src/message-queue.js';
import { UserInputCard } from '../web/src/user-input-card.js';

test('Desktop queues label their source and uncertainty without unsafe duplicate-send controls', () => {
  const render = (queue: any) => renderToStaticMarkup(createElement(DesktopQueuePanel, { queue }));
  assert.equal(render({ entries: [], available: true }), '');
  const unavailable = render({ entries: [], available: false });
  assert.match(unavailable, /暂不可用|unavailable/);
  assert.doesNotMatch(unavailable, /待发送 0|0 queued/);
  const html = render({ available: true, entries: [{ id: 'pc', text: '<script>queued</script>', hasImage: true, hasFiles: false,
    createdAt: null, status: 'paused', reason: 'Stopped' }] });
  assert.match(html, /电脑待发送 1|1 queued on Desktop/);
  assert.match(html, /已暂停|Paused/);
  assert.ok(!html.includes('<script>'));
  assert.ok(!html.includes('<button'), 'native messages cannot accidentally be sent a second time');
});

test('plan questions retain option descriptions and require an explicit answer before submitting', () => {
  const html = renderToStaticMarkup(createElement(UserInputCard, { disabled: false,
    request: async () => { throw new Error('not during render'); }, onRefresh: async () => {},
    value: { id: 'q', threadId: 't', turnId: 'turn', questions: [{ id: 'choice', header: 'Plan', question: 'Which?',
      isOther: true, isSecret: false, options: [{ label: 'A', description: 'Existing design' }] }] } }));
  assert.match(html, /Existing design/);
  assert.match(html, /textarea/);
  assert.match(html, /type="submit" disabled/);
  assert.doesNotMatch(html, /checked=/, 'rendering a question never chooses an answer');
});

test('the pending queue distinguishes stored messages from delivery and exposes cancellation', () => {
  const html = renderToStaticMarkup(createElement(MessageQueuePanel, { online: true, error: '',
    entries: [{ id: 'q', text: 'A <script>alert(1)</script>', hasImage: false, createdAt: 1, status: 'queued' }],
    onRemove: async () => {} }));
  assert.match(html, /queued|待发送/);
  assert.match(html, /button/); assert.match(html, /Remove queued message|取消排队消息/);
  assert.ok(!html.includes('<script>'));
  assert.equal(renderToStaticMarkup(createElement(MessageQueuePanel, {
    online: true, error: '', entries: [], onRemove: async () => {},
  })), '');
});

test('an empty pause does not occupy the chat; failed reads avoid pretending there are zero queued messages', () => {
  const props = { online: true, error: '', entries: [], paused: true, onRemove: async () => {}, onPause: async () => {} };
  assert.equal(renderToStaticMarkup(createElement(MessageQueuePanel, props)), '');
  const unavailable = renderToStaticMarkup(createElement(MessageQueuePanel, { ...props, error: 'offline' }));
  assert.match(unavailable, /暂时无法读取待发队列|Queue status unavailable/);
  assert.doesNotMatch(unavailable, /保留 0|0 saved|待发送 0|0 queued/);
});
