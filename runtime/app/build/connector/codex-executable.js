import { readdir, stat } from 'node:fs/promises';
import { isAbsolute, join, relative, resolve } from 'node:path';
export async function resolveCodexExecutable(configured = 'codex', options = {}) {
    const value = String(configured || 'codex').trim() || 'codex';
    const platform = options.platform || process.platform;
    if (platform !== 'win32')
        return value;
    const localAppData = options.localAppData ?? process.env.LOCALAPPDATA ?? '';
    if (!localAppData)
        return value;
    const managedBinRoot = resolve(localAppData, 'OpenAI', 'Codex', 'bin');
    const defaultCommand = value.toLowerCase() === 'codex' || value.toLowerCase() === 'codex.exe';
    if (!defaultCommand && (!isAbsolute(value) || !isInside(managedBinRoot, value)))
        return value;
    return await newestManagedCodex(managedBinRoot) || value;
}
async function newestManagedCodex(root) {
    let entries;
    try {
        entries = await readdir(root, { withFileTypes: true });
    }
    catch {
        return '';
    }
    const candidates = [join(root, 'codex.exe')]
        .concat(entries.filter((entry) => entry.isDirectory()).map((entry) => join(root, entry.name, 'codex.exe')));
    const available = await Promise.all(candidates.map(async (path) => {
        try {
            const details = await stat(path);
            return details.isFile() ? { path, modifiedAt: details.mtimeMs } : null;
        }
        catch {
            return null;
        }
    }));
    return available
        .filter((candidate) => Boolean(candidate))
        .sort((left, right) => right.modifiedAt - left.modifiedAt)[0]?.path || '';
}
function isInside(root, candidate) {
    const child = relative(root, resolve(candidate));
    return child === '' || (!child.startsWith('..') && !isAbsolute(child));
}
