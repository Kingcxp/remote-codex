import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, writeFile, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { DesktopPendingQueue } from '../src/connector/desktop-pending-queue.js';
import { userInputAnswers, userInputQuestions } from '../src/shared/user-input.js';

test('native queues merge durable and legacy input in order, isolate threads and remain read-only', async t => {
  const home = await mkdtemp(join(tmpdir(), 'desktop-pending-queue-'));
  const path = join(home, 'queue_1.sqlite'), globalPath = join(home, '.codex-global-state.json');
  const db = new DatabaseSync(path);
  t.after(async () => { db.close(); await rm(home, { recursive: true, force: true }); });
  db.exec('CREATE TABLE queued_items(id TEXT PRIMARY KEY, thread_id TEXT, payload_json TEXT, queue_order INTEGER, created_at_ms INTEGER)');
  const add = db.prepare('INSERT INTO queued_items VALUES (?,?,?,?,?)');
  add.run('second', 't', JSON.stringify({ UserInput: { content: [{ type: 'text', text: 'second message' }], client_id: 'c2' } }), 2, 20);
  add.run('first', 't', JSON.stringify({ UserInput: { content: [{ type: 'text', text: '<script>first</script>' }, { type: 'localImage', path: 'private' }], client_id: 'c1' } }), 1, 10);
  add.run('private', 'other', JSON.stringify({ UserInput: { content: [{ type: 'text', text: 'other thread' }] } }), 1, 10);
  add.run('action', 't', JSON.stringify({ InternalAction: { secret: 'not a user message' } }), 3, 30);
  const raw = JSON.stringify({ unrelatedSecret: 'never exposed', 'queued-follow-ups': { t: [
    { id: 'c1', text: 'restoration duplicate' },
    { id: 'third', text: 'paused message', pausedReason: 'Interrupted before the steer was accepted.', context: { fileAttachments: [{}] } },
    { id: 'fourth', context: { prompt: 'uncertain' }, submission: { status: 'outcome-unknown' } },
  ] } });
  await writeFile(globalPath, raw);
  const queue = new DesktopPendingQueue(home), before = await readFile(path);
  const result = await queue.list('t');
  assert.equal(result.available, true);
  assert.deepEqual(result.entries.map(e => e.id), ['desktop:first', 'desktop:second', 'desktop:third', 'desktop:fourth']);
  assert.equal(result.entries[0].hasImage, true);
  assert.equal(result.entries[2].hasFiles, true);
  assert.equal(result.entries[2].status, 'paused');
  assert.equal(result.entries[3].status, 'unknown');
  assert.ok(!JSON.stringify(result).includes('private'));
  assert.ok(!JSON.stringify(result).includes('never exposed'));
  assert.equal(await readFile(globalPath, 'utf8'), raw);
  assert.deepEqual(await readFile(path), before);
  db.prepare('DELETE FROM queued_items WHERE id = ?').run('first');
  await writeFile(globalPath, JSON.stringify({ 'queued-follow-ups': { t: [] } }));
  assert.deepEqual((await queue.list('t')).entries.map(e => e.id), ['desktop:second'], 'PC sends/deletions appear on the next poll');
  await writeFile(globalPath, '{incomplete');
  const partial = await queue.list('t');
  assert.equal(partial.available, false);
  assert.equal(partial.entries.length, 1, 'partial read failure never discards the healthy queue');
});

test('missing desktop stores mean empty queues; broken schemas mean unavailable', async t => {
  const home = await mkdtemp(join(tmpdir(), 'desktop-pending-queue-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const queue = new DesktopPendingQueue(home);
  assert.deepEqual(await queue.list('t'), { entries: [], available: true });
  const db = new DatabaseSync(join(home, 'queue_1.sqlite')); db.close();
  assert.deepEqual(await queue.list('t'), { entries: [], available: false });
});

test('question normalization and answers reject missing, foreign, malformed and unsupported answers', () => {
  const q = userInputQuestions([{ id: 'choice', question: 'Which?', options: [{ label: 'A', description: 'Choice A' }], isOther: false },
    { id: '__proto__', question: 'Other details?', isSecret: true }])!;
  assert.equal(q[1].isSecret, true);
  assert.deepEqual(userInputAnswers(q, JSON.parse('{"choice":{"answers":["A"]},"__proto__":{"answers":["custom"]}}')),
    JSON.parse('{"choice":{"answers":["A"]},"__proto__":{"answers":["custom"]}}'));
  for (const value of [{}, { choice: { answers: ['B'] }, __proto__: { answers: ['x'] } },
    { choice: { answers: ['A', 'B'] }, wrong: { answers: ['x'] } }]) assert.throws(() => userInputAnswers(q, value), /answers_invalid/);
  assert.equal(userInputQuestions([{ id: 'a', question: 'x' }, { id: 'a', question: 'y' }]), null);
  assert.equal(userInputQuestions([{ id: 'a', question: 'x', options: ['invalid'] }]), null);
});
