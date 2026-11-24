// This small wrapper exposes only browser identities. Never export registry secrets or revoke a connector.
import { DeviceRegistry } from './app/build/server/device-registry.js';
import { resolve } from 'node:path';
const [action, registryPath, id] = process.argv.slice(2);
if (!['list', 'revoke'].includes(action) || !registryPath) throw new Error('Expected list|revoke <registry path> [browser id].');
const registry = new DeviceRegistry(resolve(registryPath));
const devices = registry.listApproved().filter(d => d.role === 'client');
if (action === 'revoke') {
  if (!id || !devices.some(d => d.id === id)) throw new Error('Browser identity not found; no connector was changed.');
  if (!registry.remove('client', id)) throw new Error('Browser identity already removed.');
}
console.log(JSON.stringify(devices.filter(d => action !== 'revoke' || d.id !== id).map(d => ({ id: d.id, label: String(d.label || '').replace(/[\u0000-\u001f\u007f-\u009f]/g, ' '), approvedAt: d.approvedAt }))));
