import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const helper = fileURLToPath(new URL('../runtime/access-devices.mjs', import.meta.url));
function fixture(run) {
  const dir = mkdtempSync(join(tmpdir(), 'codex-browser-onboarding-'));
  const path = join(dir, 'devices.json');
  const approved = [
    { id: 'connector', role: 'connector', publicKey: 'connector-public', label: 'Host connector', approvedAt: 3 },
    { id: 'browser-first', role: 'client', publicKey: 'PUBLIC-MUST-NOT-EXPORT', privateKey: 'PRIVATE-MUST-NOT-EXPORT', label: 'Phone', approvedAt: 2 },
    { id: 'browser-second', role: 'client', publicKey: 'second-public', label: 'Linux', approvedAt: 1 },
  ];
  writeFileSync(path, JSON.stringify({ version: 2, approved, pending: [], browserPairings: [] }));
  try { run(path, (action, id) => spawnSync(process.execPath, [helper, action, path, ...(id ? [id] : [])], { encoding: 'utf8' })); }
  finally { rmSync(dir, { recursive: true }); }
}
test('list exports only browser metadata and no keys or connector', () => fixture((path, cli) => {
  const r = cli('list');
  assert.equal(r.status, 0, r.stderr);
  const devices = JSON.parse(r.stdout);
  assert.deepEqual(devices.map(d => d.id), ['browser-first', 'browser-second']);
  assert(!r.stdout.includes('MUST-NOT-EXPORT'));
  assert.deepEqual(Object.keys(devices[0]).sort(), ['approvedAt', 'id', 'label']);
}));
test('revoke uses stable browser ID and preserves host connector and other browser', () => fixture((path, cli) => {
  assert.equal(cli('revoke', 'browser-first').status, 0);
  const state = JSON.parse(readFileSync(path, 'utf8'));
  assert.deepEqual(state.approved.map(d => d.id), ['connector', 'browser-second']);
  assert.equal(cli('revoke', 'browser-second').status, 0);
  assert.deepEqual(JSON.parse(readFileSync(path, 'utf8')).approved.map(d => d.id), ['connector']);
}));
test('connector or missing browser cannot be revoked by this wrapper', () => fixture((path, cli) => {
  assert.notEqual(cli('revoke', 'connector').status, 0);
  assert.notEqual(cli('revoke', '999').status, 0);
  assert.equal(JSON.parse(readFileSync(path, 'utf8')).approved.length, 3);
}));
test('unsupported operation is refused', () => fixture((path, cli) => assert.notEqual(cli('approve').status, 0)));
