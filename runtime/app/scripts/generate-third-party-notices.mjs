import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const appRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const lock = JSON.parse(fs.readFileSync(path.join(appRoot, 'package-lock.json'), 'utf8'));
const tick = String.fromCharCode(96);
const escape = value => String(value).replaceAll('|', '\\|').replaceAll(tick, '\\' + tick).replace(/[\r\n]/g, ' ');
const rows = [
  '# npm third-party packages',
  '',
  'This inventory is generated from package-lock.json and installed package metadata. Refer to each package for its complete license text and any additional notices. It includes production and development build dependencies.',
  '',
  '| Package | Version | Declared license |',
  '| --- | --- | --- |',
];

for (const relative of Object.keys(lock.packages || {}).filter(name => /(^|\/)node_modules\/[^/]+(?:\/|$)/.test(name)).sort()) {
  const packagePath = path.join(appRoot, relative, 'package.json');
  if (!fs.existsSync(packagePath)) continue;
  const metadata = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
  const declared = typeof metadata.license === 'string'
    ? metadata.license
    : metadata.license?.type || 'See package metadata';
  rows.push('| ' + tick + escape(metadata.name || relative) + tick + ' | ' + tick
    + escape(metadata.version || '') + tick + ' | ' + tick + escape(declared) + tick + ' |');
}

fs.writeFileSync(path.join(appRoot, 'THIRD_PARTY_NOTICES.md'), rows.join('\n') + '\n', 'utf8');
console.log('Wrote notices for ' + (rows.length - 7) + ' installed npm packages.');
