import assert from 'node:assert/strict';
import test from 'node:test';
import { ComposerHistory, composerAction } from '../web/src/composer-input.js';

test('Enter queues, Ctrl/Command+Enter guides, and Shift+Enter or IME stays in the editor', () => {
  const event = { key: 'Enter', ctrlKey: false, metaKey: false, altKey: false, shiftKey: false };
  assert.equal(composerAction(event), 'queue');
  assert.equal(composerAction({ ...event, ctrlKey: true }), 'steer');
  assert.equal(composerAction({ ...event, metaKey: true }), 'steer');
  for (const patch of [{ shiftKey: true }, { altKey: true }, { isComposing: true }, { keyCode: 229 }]) {
    assert.equal(composerAction({ ...event, ...patch }), null);
  }
});

test('empty editor recalls exact multiline inputs and Down returns to an empty draft', () => {
  const history = new ComposerHistory(['first', 'second\nline']);
  assert.equal(history.navigate('ArrowUp', 'draft'), null);
  assert.equal(history.navigate('ArrowUp', ''), 'second\nline');
  assert.equal(history.navigate('ArrowUp', 'second\nline'), 'first');
  assert.equal(history.navigate('ArrowUp', 'first'), 'first');
  assert.equal(history.navigate('ArrowDown', 'first'), 'second\nline');
  assert.equal(history.navigate('ArrowDown', 'second\nline'), '');
  assert.equal(history.navigate('ArrowDown', ''), null);
  history.record('next');
  assert.equal(history.navigate('ArrowUp', ''), 'next');
  assert.equal(history.navigate('ArrowUp', 'edited'), null);
  history.record('next');
  assert.deepEqual(history.values(), ['first', 'second\nline', 'next']);
});
