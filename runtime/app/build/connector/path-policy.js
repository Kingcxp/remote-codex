import { posix, win32 } from 'node:path';
export function isPathWithinRoot(path, root) {
    // win32.isAbsolute('/root/file') is also true: using it here silently makes
    // Linux allowlists case-insensitive and interprets literal backslashes.
    const windowsPath = (value) => /^(?:[a-z]:[\\/]|\\\\)/i.test(value);
    if (windowsPath(path) !== windowsPath(root))
        return false;
    const api = windowsPath(root) ? win32 : posix;
    const difference = api.relative(api.resolve(root), api.resolve(path));
    return difference === ''
        || (difference !== '..' && !difference.startsWith(`..${api.sep}`) && !api.isAbsolute(difference));
}
